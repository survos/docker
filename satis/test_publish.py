import argparse
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('publish.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.run_git('init', '-q')
        self.run_git('config', 'user.name', 'Test')
        self.run_git('config', 'user.email', 'test@example.invalid')
        self.package = self.repo / 'lib/example'
        self.package.mkdir(parents=True)
        (self.package / 'composer.json').write_text(json.dumps({'name': 'survos/example', 'require': {'php': '^8.5'}}))
        (self.package / 'code.php').write_text('<?php // committed\n')
        (self.package / '.env.local').write_text('TOKEN=fixture-not-for-publication\n')
        self.commit()
        self.run_git('tag', '2.28.7')
        self.allowlist = self.root / 'packages.json'
        self.allowlist.write_text(json.dumps({'survos/example': 'lib/example'}))
        self.real_run = subprocess.run

    def run_git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args])

    def commit(self):
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'fixture')

    def args(self, **overrides):
        args = dict(repo=self.repo, data=self.root / 'data', allowlist=self.allowlist,
                    satis=Path('fake-satis'), tag='2.28.7', ref=None, version=None,
                    package=None, url='http://127.0.0.1:8743')
        args.update(overrides)
        return argparse.Namespace(**args)

    def builder(self, command, **kwargs):
        if command[:2] != ['php', 'fake-satis']:
            return self.real_run(command, **kwargs)
        config = json.loads(Path(command[3]).read_text())
        web = Path(command[4]); web.mkdir()
        packages = {}
        for archive in Path(config['repositories'][0]['url']).glob('*.zip'):
            with zipfile.ZipFile(archive) as source:
                package = json.loads(source.read('composer.json'))
            dest = web / 'dist' / archive.name; dest.parent.mkdir(exist_ok=True)
            dest.write_bytes(archive.read_bytes())
            package['dist'] = {'type': 'zip', 'url': config['homepage'] + '/dist/' + archive.name}
            packages.setdefault(package['name'], {})[package['version']] = package
        (web / 'packages.json').write_text(json.dumps({'packages': packages}))

    def publish(self, **kwargs):
        with patch.object(publisher.subprocess, 'run', side_effect=self.builder):
            publisher.publish(self.args(**kwargs))

    def test_tag_exports_committed_source_and_preserves_old_versions(self):
        (self.package / 'code.php').write_text('<?php // dirty\n')
        self.publish()
        archive = self.root / 'data/artifacts/survos--example-2.28.7.zip'
        original = archive.read_bytes()
        with zipfile.ZipFile(io.BytesIO(original)) as z:
            self.assertIn(b'committed', z.read('code.php'))
            self.assertNotIn('.env.local', z.namelist())
        self.publish()
        self.assertEqual(original, archive.read_bytes())
        self.commit(); self.run_git('tag', '2.28.8')
        self.publish(tag='2.28.8')
        self.assertTrue((self.root / 'data/current/dist' / archive.name).exists())

    def test_conflicting_version_cannot_replace_current(self):
        self.publish()
        current = (self.root / 'data/current').resolve()
        (self.package / 'code.php').write_text('changed'); self.commit()
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.publish(tag=None, ref='HEAD', version='2.28.7')
        self.assertEqual(current, (self.root / 'data/current').resolve())

    def test_failed_build_leaves_live_snapshot_untouched(self):
        self.publish()
        current = (self.root / 'data/current').resolve()
        real = self.builder
        def fail(command, **kwargs):
            if command[:2] == ['php', 'fake-satis']:
                raise subprocess.CalledProcessError(1, command)
            return real(command, **kwargs)
        with patch.object(publisher.subprocess, 'run', side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                publisher.publish(self.args())
        self.assertEqual(current, (self.root / 'data/current').resolve())

    def test_missing_survos_dependency_fails_before_publication(self):
        manifest = json.loads((self.package / 'composer.json').read_text())
        manifest['require']['survos/missing'] = '^2.0'
        (self.package / 'composer.json').write_text(json.dumps(manifest)); self.commit()
        with self.assertRaisesRegex(ValueError, 'allowlist'):
            self.publish(tag=None, ref='HEAD', version='2.28.8')
        self.assertFalse((self.root / 'data/current').exists())

    def test_remote_plain_http_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'HTTPS'):
            self.publish(url='http://packages.example.com')

if __name__ == '__main__':
    unittest.main()
