#!/usr/bin/env python3
"""Exercise a packaged release app while its SwiftPM build directory is unreadable."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
repo = Path(__file__).resolve().parent.parent
if str(repo).encode() in binary.read_bytes():
    raise SystemExit('Use a release .app (make selftest); this executable contains its source checkout path')
profile = '(version 1)(allow default)(deny file-read* (subpath ' + json.dumps(str(repo / '.build'), ensure_ascii=False) + '))'


def run(mode, root, direct=False):
    sandbox_home = root / 'home'
    temporary = root / 'tmp'
    sandbox_home.mkdir(exist_ok=True)
    temporary.mkdir(exist_ok=True)
    environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
    environment.update(HOME=str(sandbox_home), CFFIXED_USER_HOME=str(sandbox_home), TMPDIR=str(temporary),
                       SNAGBOOK_SELFTEST=mode, SNAGBOOK_CONFIG=str(root / 'config.json'))
    if direct:
        environment['SNAGBOOK_DIRECT_STORAGE'] = '1'
    command = ['/usr/bin/sandbox-exec', '-p', profile, str(binary)]
    try:
        result = subprocess.run(command, env=environment, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    except subprocess.TimeoutExpired as error:
        print(error.stdout or '', flush=True)
        print('Timed out; fixture kept at', root, flush=True)
        raise SystemExit(1)
    print(result.stdout, end='', flush=True)
    if result.returncode or 'SELFTEST PASS' not in result.stdout:
        print('Failed; fixture kept at', root, flush=True)
        raise SystemExit(1)


def fixture():
    return Path(tempfile.mkdtemp(prefix='snagbook-selftest-'))


if os.environ.get('SNAGBOOK_SELFTEST_BUNDLE_ONLY'):
    root = fixture()
    (root / 'config.json').write_text(json.dumps({'sessionsFolder': str(root / 'sessions')}))
    run('bundle-check', root)
    shutil.rmtree(root)
else:
    root = fixture()
    (root / 'config.json').write_text(json.dumps({'sessionsFolder': str(root / 'destination')}))
    (root / 'disconnected').mkdir()
    run('bundle-check', root)
    run('sync-offline', root)
    (root / 'disconnected').rename(root / 'destination')
    run('sync-recover', root)
    shutil.rmtree(root)
    root = fixture()
    (root / 'config.json').write_text(json.dumps({'sessionsFolder': str(root / 'sessions')}))
    run('1', root, direct=True)
    shutil.rmtree(root)
