import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / 'packages/nier-onedrive/sources/nier-onedrive-monitor'
loader = importlib.machinery.SourceFileLoader('monitor', str(WRAPPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
monitor = importlib.util.module_from_spec(spec)
loader.exec_module(monitor)
setup_loader = importlib.machinery.SourceFileLoader('setup', str(WRAPPER.with_name('nier-onedrive-setup')))
setup_spec = importlib.util.spec_from_loader(setup_loader.name, setup_loader)
setup = importlib.util.module_from_spec(setup_spec)
setup_loader.exec_module(setup)
REAL_DETECT_EMAIL = setup.detect_account_email


class MonitorTests(unittest.TestCase):
    def test_classifier(self):
        classifier = monitor.EventClassifier()
        transfer = classifier.classify('Downloading: Documents/a.txt ... 50%')
        self.assertEqual(transfer['path'], 'Documents/a.txt')
        self.assertEqual(transfer['progress'], 50)
        self.assertFalse(transfer['complete'])
        self.assertEqual(classifier.classify('Sync with Microsoft OneDrive is complete')['state'], 'completed')
        classifier.classify('ERROR: Upload failed')
        classifier.classify('Path: Documents/a.txt')
        error = classifier.classify('Error Message: Access denied')
        self.assertEqual(error['detail'], 'Access denied')
        self.assertEqual(error['path'], 'Documents/a.txt')

    def test_log_is_bounded_private_and_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime/events.jsonl'
            writer = monitor.JsonlWriter(path)
            for index in range(1200):
                writer.write('stdout', 'x' * 10000, {'type': 'sync-phase', 'state': 'syncing'})
            writer.write('stdout', 'ignored', None)
            writer.close()
            records = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertLessEqual(len(records), 511)
            self.assertEqual(records[-1]['sequence'], 1200)
            self.assertEqual(len(records[-1]['message']), 8192)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            monitor.JsonlWriter(path).close()
            self.assertEqual(path.read_text(), '')

    def test_streams_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.jsonl'
            code = 'import sys; print("Starting a sync with Microsoft OneDrive"); print("ERROR: broken", file=sys.stderr); sys.exit(78)'
            result = subprocess.run([sys.executable, str(WRAPPER), '--events-file', str(path), '--', sys.executable, '-c', code], capture_output=True)
            self.assertEqual(result.returncode, 78)
            self.assertIn(b'Starting a sync', result.stdout)
            self.assertIn(b'ERROR: broken', result.stderr)
            records = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual({record['stream'] for record in records}, {'stdout', 'stderr'})

    def test_signal_forwarding(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / 'ready'
            code = 'from pathlib import Path; import sys,time; Path(sys.argv[1]).touch(); time.sleep(30)'
            process = subprocess.Popen([sys.executable, str(WRAPPER), '--events-file', str(Path(directory) / 'events'), '--', sys.executable, '-c', code, str(ready)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), -signal.SIGTERM)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_config_defaults_and_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'wrapper.toml'
            config.write_text('[onedrive]\nconfig_dir="~/OneDrive config"\n')
            self.assertEqual(monitor.command_from_config(config), ['/usr/bin/onedrive', '--monitor', '--confdir=' + os.path.expanduser('~/OneDrive config')])
            config.write_text('[onedrive]\nconfig_dir="x"\nextra_args="bad"\n')
            with self.assertRaises(ValueError):
                monitor.command_from_config(config)

    def test_local_source_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / 'sources').mkdir()
            (base / 'sources/extra.txt').write_text('new')
            (base / 'example.spec').write_text('Source1: extra.txt\n')
            (base / 'out').mkdir()
            (base / 'out/extra.txt').write_text('stale')
            # Source function definitions without invoking the publication CLI.
            script = (ROOT / 'update-packages.sh').read_text().rsplit('main "$@"', 1)[0]
            script += '\ndownload_sources "$1/example.spec" 1 "$1/out" example\n'
            subprocess.run(['bash', '-c', script, 'test', directory], check=True, capture_output=True)
            self.assertEqual((base / 'out/extra.txt').read_text(), 'new')
            (base / 'example.spec').write_text('Source1: ../extra.txt\n')
            result = subprocess.run(['bash', '-c', script, 'test', directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name) / 'home'
        self.home.mkdir()
        self.environment = patch.dict(os.environ, {'HOME': str(self.home), 'XDG_CONFIG_HOME': str(self.home / '.config')})
        self.environment.start()
        self.identity = patch.object(setup, "detect_account_email", return_value="")
        self.identity_mock = self.identity.start()
        self.addCleanup(self.identity.stop)
        self.addCleanup(self.environment.stop)

    def account(self, label, folder):
        directory, data = setup.create_account(label, label + '@example.test', self.home / folder)
        (directory / 'client/refresh_token').write_text('simulated-token')
        setup.publish_account(directory, data)
        return directory, data

    def test_identity_detects_drive_owner_without_exposing_or_rewriting_tokens(self):
        directory, data = self.account('Work', 'work')
        token_path = directory / 'client/refresh_token'
        before = token_path.read_bytes()
        responses = [{'access_token': 'PRIVATE-ACCESS', 'refresh_token': 'NEW-PRIVATE'},
                     {'owner': {'user': {'email': 'actual@example.test'}}}]
        with patch.object(setup, 'identity_json', side_effect=responses) as request:
            self.assertEqual(REAL_DETECT_EMAIL(directory / 'client'), 'actual@example.test')
        self.assertEqual(request.call_args_list[0].args[0].get_method(), 'POST')
        self.assertEqual(request.call_args_list[1].args[0].full_url,
                         'https://graph.microsoft.com/v1.0/me/drive?$select=owner')
        self.assertEqual(token_path.read_bytes(), before)
        self.assertNotIn('PRIVATE', (directory / 'account.json').read_text())

    def test_identity_custom_cloud_and_profile_fallback(self):
        directory, data = self.account('Work', 'work')
        (directory / 'client/config').write_text('application_id = "custom-id"\n'
            'azure_ad_endpoint = "USL5"\nazure_tenant_id = "tenant-id"\n')
        with patch.object(setup, 'identity_json', side_effect=[{'access_token': 'secret'},
                {'owner': {'user': {}}}, {'mail': None, 'userPrincipalName': 'work@example.test'}]) as request:
            self.assertEqual(REAL_DETECT_EMAIL(directory / 'client'), 'work@example.test')
        self.assertTrue(request.call_args_list[0].args[0].full_url.startswith('https://login.microsoftonline.us/tenant-id/'))
        self.assertIn(b'client_id=custom-id', request.call_args_list[0].args[0].data)
        self.assertTrue(request.call_args_list[1].args[0].full_url.startswith('https://dod-graph.microsoft.us/'))

    def test_existing_identity_refresh_preserves_account_and_updates_private_metadata(self):
        directory, data = self.account('Work', 'work')
        self.identity_mock.return_value = 'actual@example.test'
        with patch.object(setup, 'systemctl') as control:
            self.assertTrue(setup.refresh_account_identity(data['id']))
        saved = json.loads((directory / 'account.json').read_text())
        self.assertEqual(saved['email'], 'actual@example.test')
        self.assertEqual(saved['emailSource'], 'microsoft')
        self.assertEqual(saved['label'], 'Work')
        self.assertEqual(saved['syncDir'], data['syncDir'])
        self.assertEqual((directory / 'account.json').stat().st_mode & 0o777, 0o600)
        control.assert_not_called()
        before = (directory / 'account.json').read_bytes()
        self.identity_mock.side_effect = OSError('PRIVATE error body')
        self.assertFalse(setup.refresh_account_identity(data['id']))
        self.assertEqual((directory / 'account.json').read_bytes(), before)

    def test_invalid_identity_configuration_never_sends_credentials(self):
        directory, data = self.account('Work', 'work')
        for config in ['azure_ad_endpoint = "https://evil.test"',
                       'azure_tenant_id = "../evil"']:
            (directory / 'client/config').write_text(config)
            with patch.object(setup, 'identity_json') as request, self.assertRaises(ValueError):
                REAL_DETECT_EMAIL(directory / 'client')
            request.assert_not_called()
        self.assertEqual(setup.valid_email('name@example.test\nInjected'), '')

    def test_independent_accounts_and_wrapper_commands(self):
        first, a = self.account('Personal', 'personal')
        second, b = self.account('Work', 'work')
        accounts = setup.read_accounts()
        self.assertEqual(len(accounts), 2)
        self.assertNotEqual(a['id'], b['id'])
        commands = [monitor.command_from_config(path / 'monitor-wrapper.toml') for path in (first, second)]
        self.assertNotEqual(commands[0][2], commands[1][2])
        self.assertTrue(all(command[:2] == ['/usr/bin/onedrive', '--monitor'] for command in commands))
        self.assertNotIn('simulated-token', json.dumps(accounts))
        for directory in (first, second):
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            self.assertEqual((directory / 'account.json').stat().st_mode & 0o777, 0o600)

    def test_authentication_required_before_publishing(self):
        directory, data = setup.create_account('Work', '', self.home / 'sync')
        self.assertEqual(setup.read_accounts(), [])
        with self.assertRaises(ValueError):
            setup.publish_account(directory, data)
        self.assertFalse((directory / 'account.json').exists())

    def test_folders_are_separate_empty_and_outside_config(self):
        self.account('Personal', 'personal')
        for value in [self.home, self.home / 'personal', self.home / 'personal/nested',
                      self.home / '.config/new', Path('/')]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                setup.validate_folder(str(value), setup.read_accounts())
        folder = self.home / 'files'
        folder.mkdir()
        (folder / 'important').touch()
        with self.assertRaises(ValueError):
            setup.validate_folder(str(folder), [])
        self.assertEqual(setup.validate_folder(str(self.home / 'new'), setup.read_accounts()), self.home / 'new')

    def test_multiple_widgets_preserve_preferences_and_replace_placeholder(self):
        path = self.home / '.config/nier/shell.json'
        path.parent.mkdir(parents=True)
        original = {'bar': {'position': 'bottom', 'layout': {'left': [{'id': 'nier.clock'}], 'center': [],
                    'right': [{'id': 'nier.onedrive', 'customSetting': True}]}}, 'idle': {'lock': 123}}
        path.write_text(json.dumps(original))
        setup.add_bar_widget('personal-123')
        setup.add_bar_widget('work-456')
        setup.add_bar_widget('work-456')
        data = json.loads(path.read_text())
        self.assertEqual(data['bar']['position'], 'bottom')
        self.assertEqual(data['idle'], {'lock': 123})
        entries = data['bar']['layout']['right']
        self.assertEqual([entry['account'] for entry in entries], ['personal-123', 'work-456'])
        self.assertTrue(entries[0]['customSetting'])
        self.assertTrue(list(path.parent.glob('shell.json.before-onedrive-*')))

    def test_default_service_is_discovered_without_copying_credentials(self):
        config = self.home / '.config/onedrive'
        config.mkdir(parents=True)
        (config / 'refresh_token').write_text('private')
        (config / 'config').write_text('sync_dir = "~/Legacy OneDrive"\n')
        accounts = setup.read_accounts()
        self.assertEqual(accounts[0]['unit'], 'onedrive.service')
        self.assertEqual(accounts[0]['eventsDirectory'], 'nier-onedrive')
        self.assertEqual(accounts[0]['syncDir'], str(self.home / 'Legacy OneDrive'))
        self.assertFalse(setup.accounts_root().exists())

    def test_wizard_auth_preview_and_start_are_explicit(self):
        commands = []
        self.identity_mock.return_value = "detected@example.test"
        home = self.home
        class FakeUi:
            answers = iter(['Personal', 'me@example.test', str(home / 'Personal')])
            choices = iter([0, 1])  # Save without syncing; leave bar unchanged.
            def ask(self, *args): return next(self.answers)
            def choose(self, *args): return next(self.choices)
            def message(self, *args): pass
            def command(self, title, command):
                commands.append(command)
                confdir = Path(next(arg.split('=', 1)[1] for arg in command if arg.startswith('--confdir=')))
                (confdir / 'refresh_token').write_text('fake')
                return True
        with patch.object(setup, 'systemctl') as control:
            setup.add_account(FakeUi())
        control.assert_not_called()
        self.assertEqual(len(setup.read_accounts()), 1)
        self.assertEqual(setup.read_accounts()[0]["email"], "detected@example.test")
        self.assertEqual(len(commands), 2)
        self.assertNotIn('--monitor', commands[0])
        self.assertIn('--dry-run', commands[1])
        self.assertIn('--sync', commands[1])
        self.assertNotIn('--synchronize', commands[1])

    def test_failed_signin_removes_only_unpublished_config(self):
        home = self.home
        class FakeUi:
            answers = iter(['Failed account', '', str(home / 'Sync')])
            def ask(self, *args): return next(self.answers)
            def message(self, *args): pass
            def command(self, *args): return False
        with self.assertRaises(ValueError):
            setup.add_account(FakeUi())
        self.assertEqual(list(setup.accounts_root().iterdir()), [])
        self.assertTrue((self.home / 'Sync').is_dir())

    def test_explicit_enable_targets_new_account_only(self):
        home = self.home
        class FakeUi:
            answers = iter(['Work', 'work@example.test', str(home / 'Work')])
            choices = iter([1, 1])
            def ask(self, *args): return next(self.answers)
            def choose(self, *args): return next(self.choices)
            def message(self, *args): pass
            def command(self, title, command):
                directory = Path(next(arg.split('=', 1)[1] for arg in command if arg.startswith('--confdir=')))
                (directory / 'refresh_token').write_text('fake')
                return True
        with patch.object(setup, 'systemctl') as control:
            setup.add_account(FakeUi())
        account = setup.read_accounts()[0]
        self.assertEqual(control.call_args_list[0].args, ('daemon-reload',))
        self.assertEqual(control.call_args_list[1].args, ('enable', '--now', account['unit']))
        self.assertEqual(control.call_count, 2)

    def test_preview_failure_preserves_signin_and_resume_skips_authentication(self):
        directory, data = self.account('Work', 'Work')
        (directory / 'account.json').unlink()
        setup.atomic_write(directory / 'setup.json', json.dumps(data))
        calls = []
        class FailedPreview:
            def command(self, title, command):
                calls.append(command)
                return False
        with self.assertRaisesRegex(ValueError, 'sign-in is saved'):
            setup.complete_account(FailedPreview(), directory, data)
        self.assertTrue((directory / 'client/refresh_token').exists())
        self.assertEqual(setup.pending_accounts()[0][1]['id'], data['id'])
        self.assertEqual(setup.read_accounts(), [])
        self.assertEqual(len(calls), 1)
        self.assertIn('--sync', calls[0])
        self.assertIn('--dry-run', calls[0])
        class Resume:
            choices = iter([0, 1])
            def command(self, title, command):
                calls.append(command)
                return True
            def choose(self, *args): return next(self.choices)
            def message(self, *args): pass
        with patch.object(setup, 'systemctl') as control:
            setup.complete_account(Resume(), directory, data)
        control.assert_not_called()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all('--dry-run' in command for command in calls))
        self.assertFalse((directory / 'setup.json').exists())
        self.assertEqual(setup.pending_accounts(), [])
        self.assertEqual(setup.read_accounts()[0]['id'], data['id'])

    def test_worker_threads_are_limited_to_available_cpus(self):
        for cpus, expected in [(4, 4), (32, 8), (None, 1)]:
            with patch.object(setup.os, 'cpu_count', return_value=cpus):
                directory, _ = setup.create_account('Work', '', self.home / 'sync')
            self.assertIn(f'threads = "{expected}"', (directory / 'client/config').read_text())


if __name__ == '__main__':
    unittest.main()
