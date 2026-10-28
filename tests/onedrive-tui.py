import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

source = Path(os.environ.get('ONEDRIVE_SETUP_UNDER_TEST', Path(__file__).resolve().parents[1] / 'packages/nier-onedrive/sources/nier-onedrive-setup'))
with tempfile.TemporaryDirectory(prefix='nier-od-tui-') as temporary:
    base = Path(temporary)
    home = base / 'home'
    home.mkdir()
    shell = home / '.config/nier/shell.json'
    shell.parent.mkdir(parents=True)
    shell.write_text(json.dumps({'bar': {'layout': {'left': [], 'center': [{'id':'nier.clock'}], 'right': [{'id':'nier.onedrive'}]}}}))
    client = base / 'fake-onedrive'
    client.write_text('''#!/usr/bin/env python3
import sys
from pathlib import Path
confdir=Path(next(a.split('=',1)[1] for a in sys.argv if a.startswith('--confdir=')))
if '--dry-run' in sys.argv and '--sync' not in sys.argv: raise SystemExit('Preview must use --sync')
if '--synchronize' in sys.argv: raise SystemExit('Unsupported legacy option')
(confdir/'refresh_token').write_text('TEST-TOKEN')
print('PREVIEW_STUB_COMPLETED' if '--dry-run' in sys.argv else 'AUTH_STUB_COMPLETED', flush=True)
''')
    client.chmod(0o755)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 110, 0, 0))
    code = '''import importlib.machinery, importlib.util, sys
loader=importlib.machinery.SourceFileLoader('wizard',sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec);loader.exec_module(m)
m.CLIENT=sys.argv[2]\nm.detect_account_email=lambda client: "detected@example.test"
sys.argv=sys.argv[:1]
raise SystemExit(m.main())'''
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), TERM='xterm-256color', PYTHONDONTWRITEBYTECODE='1')
    child = subprocess.Popen(['python3', '-c', code, str(source), str(client)], stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
    os.close(slave)
    transcript = bytearray()
    offset = 0
    def wait_for(text):
        global offset
        deadline = time.monotonic()+7
        while time.monotonic()<deadline:
            location=transcript.find(text.encode(), offset)
            if location >= 0:
                offset=location+len(text.encode())
                return
            if select.select([master], [], [], .1)[0]:
                try: transcript.extend(os.read(master, 65536))
                except OSError: break
        raise AssertionError('Missing '+text+'\n'+transcript.decode(errors='replace'))
    def send(text): os.write(master, text.encode())
    try:
        wait_for('Accounts');send('\n')
        wait_for('Account label');send('Personal\n')
        wait_for('Email address');send('me@example.test\n')
        wait_for('Choose a new or empty');send('\n')
        wait_for('Sign in');send('\n')
        wait_for('Microsoft sign-in');send('\n')
        wait_for('AUTH_STUB_COMPLETED');wait_for('Press Enter');send('\n')
        wait_for('Preview synchronization');send('\n')
        wait_for('PREVIEW_STUB_COMPLETED');wait_for('Press Enter');send('\n')
        wait_for('Account ready');send('\n')
        wait_for('Add a widget for this account');send('\n')
        wait_for('You can add another account');send('\n')
        time.sleep(.2);send('\x1b')
        assert child.wait(timeout=5)==0
        accounts=list((home/'.config/nier/onedrive/accounts').glob('*/account.json'))
        assert len(accounts)==1
        account=json.loads(accounts[0].read_text())
        entry=json.loads(shell.read_text())['bar']['layout']['right'][0]
        assert entry['account']==account['id']
        assert account['email']=='detected@example.test'
        assert (accounts[0].parent/'client/refresh_token').stat().st_mode & 0o777 == 0o600
        print('Full curses wizard passed: fields, simulated sign-in, dry-run, save without syncing, account widget, exit')
    finally:
        if child.poll() is None: child.kill();child.wait()
        os.close(master)
        if os.environ.get('ONEDRIVE_TUI_TRANSCRIPT'):
            Path(os.environ['ONEDRIVE_TUI_TRANSCRIPT']).write_bytes(transcript)
