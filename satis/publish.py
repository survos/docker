#!/usr/bin/env python3
"""Selective, committed-source publication. No tags or source files are modified."""
import argparse
import fcntl
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid
import zipfile
from urllib.parse import urlsplit


def git(repo, *args):
    return subprocess.check_output(['git', '-c', f'safe.directory={repo.resolve()}', '-C', str(repo), *args])


def publish(args):
    if args.tag:
        if args.ref or args.version:
            raise ValueError('Use --tag OR --ref/--version')
        args.ref = 'refs/tags/' + args.tag
        args.version = args.tag.removeprefix('v')
    if not args.ref or not args.version:
        raise ValueError('Supply --tag, or both --ref and --version')
    data = args.data.resolve()
    data.mkdir(parents=True, exist_ok=True)
    with (data / '.publish.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        commit = git(args.repo, 'rev-parse', '--verify', args.ref + '^{commit}').decode().strip()
        catalog = json.loads(args.allowlist.read_text())
        selected = args.package or list(catalog)
        if any(name not in catalog for name in selected):
            raise ValueError('Every package must appear in packages.json')
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-(?:alpha|beta|RC)\d+)?', args.version):
            raise ValueError('Use a release version such as 0.0.1 or 0.0.1-alpha1')
        url = urlsplit(args.url)
        if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError('Base URL must be HTTP(S), without credentials, query or fragment')
        if url.scheme == 'http' and url.hostname not in ('localhost', '127.0.0.1', '[::1]', '::1'):
            raise ValueError('HTTP is only allowed for loopback testing; use HTTPS remotely')
        # Report a partial migration before publishing a registry that silently falls
        # back to GitHub for dependencies in our namespace.
        for name in selected:
            manifest = json.loads(git(args.repo, 'show', f'{commit}:{catalog[name]}/composer.json'))
            missing = [dep for dep in manifest.get('require', {}) if dep.startswith('survos/') and dep not in catalog]
            if missing:
                raise ValueError(f'{name}: add required packages to the allowlist: {missing}')
        artifacts = data / 'artifacts'
        artifacts.mkdir(exist_ok=True)
        prepared = []
        with tempfile.TemporaryDirectory(dir=data, prefix='.staging-') as temporary:
            stage = Path(temporary)
            inputs = stage / 'artifacts'
            shutil.copytree(artifacts, inputs)
            for name in selected:
                path = catalog[name]
                if not re.fullmatch(r'(bu|lib)/[a-zA-Z0-9_-]+', path):
                    raise ValueError(f'Invalid package directory: {path}')
                raw = git(args.repo, 'archive', '--format=zip', f'{commit}:{path}')
                with zipfile.ZipFile(io.BytesIO(raw)) as source:
                    manifest = json.loads(source.read('composer.json'))
                    if manifest['name'] != name:
                        raise ValueError(f'Manifest identity mismatch for {path}')
                    manifest['version'] = args.version
                    manifest.pop('source', None)
                    manifest.pop('dist', None)
                    manifest.setdefault('extra', {})['survos-release'] = {
                        'commit': commit, 'path': path, 'ref': args.ref
                    }
                    filename = name.replace('/', '--') + '-' + args.version + '.zip'
                    output = inputs / filename
                    if output.exists():
                        with zipfile.ZipFile(output) as old:
                            previous = json.loads(old.read('composer.json'))
                        if previous != manifest:
                            raise ValueError(f'Refusing to replace immutable version {name} {args.version}')
                        print(f'Reusing {name} {args.version}', flush=True)
                        continue
                    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as target:
                        for item in source.infolist():
                            parts = Path(item.filename).parts
                            if item.filename.startswith('/') or '..' in parts:
                                raise ValueError('Unsafe archive path')
                            if any(p in ('vendor', 'node_modules', '.git') or p.startswith('.env') for p in parts):
                                continue
                            contents = json.dumps(manifest, indent=2).encode() if item.filename == 'composer.json' else source.read(item)
                            target.writestr(item, contents)
                    prepared.append(filename)
            build = stage / 'web'
            config = {
                'name': 'survos/satis-pilot', 'homepage': args.url.rstrip('/'),
                'repositories': [{'type': 'artifact', 'url': str(inputs)}],
                'require-all': True,
                'archive': {'directory': 'dist', 'format': 'zip', 'rearchive': False, 'checksum': True}
            }
            config_file = stage / 'satis.json'
            config_file.write_text(json.dumps(config, indent=2))
            subprocess.run(['php', str(args.satis), 'build', str(config_file), str(build), '--no-interaction'], check=True)
            # Fail closed if any generated dist still references a build-machine path.
            def verify(value):
                if isinstance(value, dict):
                    if 'dist' in value:
                        dist = value['dist']
                        prefix = args.url.rstrip('/') + '/'
                        if dist.get('type') != 'zip' or not dist.get('url', '').startswith(prefix):
                            raise ValueError(f'Non-portable dist: {dist}')
                        relative = dist['url'][len(prefix):]
                        if '..' in Path(relative).parts or not (build / relative).is_file():
                            raise ValueError(f'Missing download: {relative}')
                    for child in value.values():
                        verify(child)
                elif isinstance(value, list):
                    for child in value:
                        verify(child)
            for file in build.rglob('*.json'):
                verify(json.loads(file.read_text()))
            # Retain old hash-addressed metadata as well as archives for in-flight clients.
            current = data / 'current'
            if current.exists():
                for old in current.resolve().rglob('*'):
                    target = build / old.relative_to(current.resolve())
                    if old.is_file() and not target.exists():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(old, target)
            for filename in prepared:
                shutil.copy2(inputs / filename, artifacts / filename)
            releases = data / 'releases'
            releases.mkdir(exist_ok=True)
            release = releases / uuid.uuid4().hex
            shutil.move(str(build), release)
            link = data / '.current-next'
            link.unlink(missing_ok=True)
            link.symlink_to(release.relative_to(data), target_is_directory=True)
            os.replace(link, current)
        print(f'Published {len(selected)} selected package(s) from {commit} at {args.url}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path('/mono'))
    parser.add_argument('--data', type=Path, default=Path('/data'))
    parser.add_argument('--allowlist', type=Path, default=Path(__file__).with_name('packages.json'))
    parser.add_argument('--satis', type=Path, default=Path('/satis/bin/satis'))
    parser.add_argument('--tag', help='Existing release tag; derives the version and pins its commit')
    parser.add_argument('--ref', help='Existing commit or tag; never creates a tag')
    parser.add_argument('--version')
    parser.add_argument('--url', required=True, help='URL reachable by package consumers')
    parser.add_argument('--package', action='append', help='Allowlisted package; repeatable')
    publish(parser.parse_args())
