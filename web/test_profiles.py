"""Offline profile/schedule contracts. Uses temporary homes and fake tokens."""
import base64
import contextlib
import datetime as dt
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import runner
import store


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        (self.state / 'credentials').mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.repo = store.Store(self.state, self.bin)
        self.repo.prepare()
        self.originals = {}
        for provider in ('claude', 'codex'):
            path = self.state / 'credentials' / (provider + '.json')
            path.write_text(json.dumps({'fixture': provider}))
            self.originals[path] = path.read_bytes()

    def tearDown(self):
        self.temp.cleanup()

    def imported(self, provider='codex'):
        payload = {'tokens': {'access_token': 'fixture-token', 'refresh_token': 'never-save'}}
        normalized = {'tokens': {'access_token': 'fixture-token'}}
        if provider == 'claude':
            payload = {'claudeAiOauth': {'accessToken': 'sk-ant-oat01-fixture', 'refreshToken': 'never-save'}}
            normalized = {'claudeAiOauth': {'accessToken': 'sk-ant-oat01-fixture'}}
        with patch.object(store, 'normalize_authorization', return_value=normalized):
            return self.repo.import_account({'provider': provider, 'name': 'Windows fixture', 'authorization': payload})

    def test_defaults_preserve_existing_schedule_and_accounts(self):
        settings = self.repo.settings()
        self.assertEqual(settings['times'], ['06:00', '11:01', '16:02', '21:03'])
        self.assertEqual(settings['scheduled_accounts'], ['server-claude', 'server-codex'])
        self.assertEqual([a['id'] for a in self.repo.accounts()], ['server-claude', 'server-codex'])

    def test_settings_validation_is_atomic(self):
        original = self.repo.save_settings(self.repo.settings())
        tests = [dict(original, times=['24:00']), dict(original, times=['06:00', '06:00']),
                 dict(original, timezone='Unknown/Timezone'), dict(original, enabled='yes'),
                 dict(original, scheduled_accounts=['../../root']),
                 dict(original, scheduled_accounts=[]),
                 dict(original, models={'claude': 'haiku;id', 'codex': 'gpt'}),
                 dict(original, default_accounts={'claude': 'server-codex', 'codex': 'server-codex'})]
        for value in tests:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.repo.save_settings(value)
            self.assertEqual(self.repo.settings(), original)
        updated = self.repo.save_settings(dict(original, enabled=False, times=['21:00', '09:00']))
        self.assertEqual(updated['times'], ['09:00', '21:00'])
        self.assertFalse(updated['enabled'])

    def test_import_private_home_no_tokens_in_metadata_or_default_changes(self):
        account = self.imported()
        path = self.repo.credential_path(account['id'], 'codex')
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.repo.root.stat().st_mode & 0o777, 0o700)
        self.assertNotIn('never-save', path.read_text())
        self.assertNotIn('fixture-token', json.dumps(self.repo.accounts()))
        self.assertNotIn(account['id'], self.repo.settings()['scheduled_accounts'])
        for original, value in self.originals.items():
            self.assertEqual(original.read_bytes(), value)

    def test_update_same_id_and_archive_delete_prunes_settings(self):
        account = self.imported()
        settings = self.repo.settings()
        settings['scheduled_accounts'] = [account['id']]
        settings['default_accounts']['codex'] = account['id']
        self.repo.save_settings(settings)
        with patch.object(store, 'normalize_authorization', return_value={'tokens': {'access_token': 'replacement'}}):
            updated = self.repo.import_account({'id': account['id'], 'provider': 'codex',
                         'name': 'Updated', 'authorization': {'tokens': {'access_token': 'replacement'}}})
        self.assertEqual(updated['id'], account['id'])
        self.assertEqual(len(self.repo.accounts()), 3)
        self.repo.delete_account(account['id'])
        self.assertEqual(len(self.repo.accounts()), 2)
        self.assertFalse(self.repo.settings()['enabled'])
        self.assertEqual(self.repo.settings()['default_accounts']['codex'], 'server-codex')
        self.assertTrue(list((self.repo.root / 'backups').glob(account['id'] + '-*')))

    def test_rejects_unknown_profiles_names_and_builtin_delete(self):
        for identifier in ('../../root', 'unknown', 'server-claude'):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                self.repo.delete_account(identifier)
        with self.assertRaises(ValueError):
            self.repo.import_account({'provider': 'codex', 'name': 'bad\nname', 'authorization': {}})
        with self.assertRaises(ValueError):
            self.repo.import_account({'id': 0, 'provider': 'codex', 'name': 'Valid', 'authorization': {}})

    def test_run_uses_profile_home_and_wrong_provider_cannot_run(self):
        account = self.imported()
        with patch.object(runner, 'STATE', self.state), patch.object(runner, 'BIN', self.bin), \
                patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'OK: ok')) as execute:
            result = runner.run('codex', 'haiku', 'gpt-5.6-luna', 'server-claude', account['id'])
            self.assertEqual(result['exit_code'], 0)
            self.assertEqual(execute.call_args.kwargs['env']['HOME'], str(self.repo.root / 'accounts' / account['id']))
            execute.reset_mock()
            with self.assertRaises(ValueError):
                runner.run('claude', 'haiku', 'gpt', account['id'], 'server-codex')
            execute.assert_not_called()

    def test_schedule_selected_accounts_pause_and_same_minute_deduplication(self):
        account = self.imported()
        settings = self.repo.settings()
        settings.update(times=['09:00'], scheduled_accounts=[account['id']])
        self.repo.save_settings(settings)
        now = dt.datetime(2026, 10, 9, 9, 0, tzinfo=dt.timezone(dt.timedelta(hours=3)))
        with patch.object(runner, 'STATE', self.state), patch.object(runner, 'BIN', self.bin), \
                patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'OK: ok')) as execute:
            self.assertEqual(runner.scheduled(now)['exit_code'], 0)
            self.assertEqual(execute.call_count, 1)
            self.assertTrue(runner.scheduled(now)['skipped'])
            self.assertEqual(execute.call_count, 1)
            settings['enabled'] = False
            self.repo.save_settings(settings)
            self.assertTrue(runner.scheduled(now + dt.timedelta(days=1))['skipped'])
            self.assertEqual(execute.call_count, 1)

    def test_management_error_does_not_change_credentials(self):
        with patch.object(runner, 'STATE', self.state), patch.object(runner, 'BIN', self.bin):
            with self.assertRaises(ValueError):
                runner.manage({'operation': 'shell', 'command': 'id'})
            with patch.object(store, 'normalize_authorization', side_effect=ValueError('Invalid authorization')):
                with self.assertRaises(ValueError):
                    runner.manage({'operation': 'import', 'provider': 'codex', 'name': 'Fixture', 'authorization': {}})
        for path, value in self.originals.items():
            self.assertEqual(path.read_bytes(), value)

    def test_installed_importer_strips_refresh_tokens_and_rejects_api_key(self):
        directory = Path(__file__).resolve().parent.parent
        if not (directory / 'ai-ping.py').is_file():
            directory = Path('/root/.local/bin')
        value = store.normalize_authorization(directory, 'codex', {'tokens': {
            'access_token': 'fixture-access', 'refresh_token': 'never-save', 'account_id': 'fixture-account'}})
        self.assertEqual(value, {'tokens': {'access_token': 'fixture-access', 'account_id': 'fixture-account'}})
        with self.assertRaises(ValueError):
            store.normalize_authorization(directory, 'codex', {'tokens': {'access_token': 'sk-api-fixture'}})


if __name__ == '__main__':
    unittest.main()
