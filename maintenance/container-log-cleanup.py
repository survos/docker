#!/usr/bin/env python3
"""Bound unrotated Docker JSON logs without restarting production containers.

Interim safeguard: native Docker rotation should replace this after services can
be recreated with max-size/max-file. Never rename/unlink Docker's active files.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time

LIMIT = 100 * 1024 * 1024
KEEP = 10 * 1024 * 1024

def trim(path, archive, apply=False):
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size <= LIMIT:
            return 0
        if not apply:
            return info.st_size
        # Preserve complete recent records before clearing the active inode.
        os.lseek(fd, max(0, info.st_size - KEEP), os.SEEK_SET)
        tail = os.read(fd, KEEP)
        if info.st_size > KEEP:
            tail = tail.partition(b'\n')[2]
        tail = tail.rpartition(b'\n')[0] + b'\n'
        temp = archive.with_suffix('.tmp')
        out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(out, 'wb') as stream:
            stream.write(tail)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, archive)
        os.ftruncate(fd, 0)
        return info.st_size
    finally:
        os.close(fd)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Clear oversized logs; default is dry run')
    args = parser.parse_args()
    archive_dir = Path('/var/log/container-log-cleanup')
    archive_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open('/run/lock/container-log-cleanup.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        ids = subprocess.check_output(['/usr/bin/docker', 'ps', '-aq'], text=True).split()
        if not ids:
            return
        containers = json.loads(subprocess.check_output(['/usr/bin/docker', 'inspect', *ids], text=True))
        for c in containers:
            config = c['HostConfig']['LogConfig']
            if config['Type'] != 'json-file' or config.get('Config', {}).get('max-size') not in (None, '', '-1'):
                continue
            cid = c['Id']
            if not re.fullmatch('[0-9a-f]{64}', cid):
                continue
            path = Path(c.get('LogPath') or '/')
            expected = Path('/var/lib/docker/containers') / cid / (cid + '-json.log')
            if path != expected:
                continue
            try:
                size = trim(path, archive_dir / (cid + '.json.log'), args.apply)
            except FileNotFoundError:
                continue # Container removed during enumeration.
            if size:
                print(('Cleared' if args.apply else 'Would clear'), c['Name'], f'{size / 1024**2:.1f} MiB', flush=True)
        if args.apply:
            for path in archive_dir.glob('*.json.log'):
                if path.stat().st_mtime < time.time() - 7 * 86400:
                    path.unlink()

if __name__ == '__main__':
    main()
