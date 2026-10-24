"""Offline checks for dedicated server auth: no live account or network."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
import urllib.error

import codex_auth as auth

spec = importlib.util.spec_from_file_location('ping', Path(__file__).with_name('ai-ping.py'))
ping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ping)


def value(seconds=7200, account='fixture'):
    part = base64.urlsafe_b64encode(json.dumps({'exp': time.time()+seconds}).encode()).decode().rstrip('=')
    return {'tokens': {'access_token': 'x.'+part+'.x', 'refresh_token': 'private-fixture', 'account_id': account}}


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for patcher in (patch.object(auth.Path, 'home', return_value=self.root), patch.dict(os.environ, {}, clear=True)):
            patcher.start()
            self.addCleanup(patcher.stop)
        auth.home().mkdir(parents=True)
        self.save(value())

    def save(self, data):
        auth.auth_path().write_text(json.dumps(data))

    def test_fresh_token_needs_no_cli(self):
        with patch.object(auth, 'refresh') as refresh:
            auth.ensure_fresh()
            refresh.assert_not_called()
        self.assertEqual(auth.auth_path().stat().st_mode & 0o777, 0o600)

    def test_expired_token_is_renewed(self):
        self.save(value(-10))
        with patch.object(auth, 'refresh', side_effect=lambda: self.save(value())) as refresh:
            auth.ensure_fresh()
            refresh.assert_called_once()

    def test_refresh_error_preserves_existing_file(self):
        old = auth.auth_path().read_bytes()
        with patch.object(auth, 'refresh', side_effect=auth.AuthError('failed')):
            with self.assertRaises(auth.AuthError): auth.ensure_fresh(force=True)
        self.assertEqual(auth.auth_path().read_bytes(), old)

    def test_changed_account_rejected(self):
        with patch.object(auth, 'refresh', side_effect=lambda: self.save(value(account='other'))):
            with self.assertRaises(auth.AuthError): auth.ensure_fresh(force=True)

    def test_source_selection_and_custom_home(self):
        self.assertEqual(ping.auth_path('codex'), auth.auth_path())
        with patch.dict(os.environ, CODEX_HOME=str(self.root/'custom')):
            self.assertFalse(auth.active())

    def test_repeat_setup_reuses_session(self):
        with patch.object(auth, 'install_cli'), patch.object(auth.subprocess, 'run') as run:
            self.assertFalse(auth.setup())
            run.assert_not_called()

    def test_new_device_login(self):
        auth.auth_path().unlink()
        def login(*args, **kwargs):
            self.assertIn('--device-auth', args[0])
            self.assertEqual(kwargs['env']['CODEX_HOME'], str(auth.home()))
            self.save(value())
            return type('Result', (), {'returncode': 0})()
        with patch.object(auth, 'install_cli'), patch.object(auth.subprocess, 'run', side_effect=login):
            self.assertTrue(auth.setup())

    def test_checksum_failure_does_not_install(self):
        with patch.object(auth.platform, 'system', return_value='Linux'), patch.object(auth.platform, 'machine', return_value='x86_64'):
            with patch.object(auth.urllib.request, 'urlopen', return_value=io.BytesIO(b'invalid')):
                with self.assertRaises(auth.AuthError): auth.install_cli()
        self.assertFalse(auth.binary().exists())

    def test_verified_binary_install_and_repeat(self):
        import hashlib
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            member = tarfile.TarInfo('codex-x86_64-unknown-linux-musl')
            member.size = 7
            archive.addfile(member, io.BytesIO(b'fixture'))
        body = data.getvalue()
        with patch.object(auth.platform, 'system', return_value='Linux'), patch.object(auth.platform, 'machine', return_value='x86_64'), patch.object(auth, 'SHA256', hashlib.sha256(body).hexdigest()):
            with patch.object(auth.urllib.request, 'urlopen', return_value=io.BytesIO(body)) as download:
                auth.install_cli()
                auth.install_cli()
                download.assert_called_once()
        self.assertEqual(auth.binary().read_bytes(), b'fixture')

    def test_managed_401_refreshes_once_and_retries_minimal_request(self):
        calls = []
        def request(url, headers, body=None, timeout=30):
            calls.append(headers['Authorization'])
            self.assertEqual(body['tools'], [])
            if len(calls) == 1:
                raise urllib.error.HTTPError(url, 401, '', {}, None)
            return 'data: '+json.dumps({'type':'response.completed','response':{'usage':{'input_tokens':1}}})
        with patch.object(auth, 'ensure_fresh') as refresh, patch.object(ping, 'request', side_effect=request):
            ping.codex_ping('gpt-5.6-luna')
            self.assertEqual(refresh.call_args_list, [unittest.mock.call(), unittest.mock.call(force=True)])
        self.assertEqual(len(calls), 2)

    def test_setup_verifies_new_login_only(self):
        for new, expected in ((True, 1), (False, 0)):
            with patch.object(auth, 'setup', return_value=new), patch.object(auth, 'ensure_fresh'), patch.object(ping, 'codex_ping', return_value=('ok', {}, False)) as model, patch.object(ping, 'write_limits'), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ping.main(['--setup-linux', 'codex', 'gpt-5.6-luna']), 0)
                self.assertEqual(model.call_count, expected)


unittest.main()
