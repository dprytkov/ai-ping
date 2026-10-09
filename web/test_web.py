"""Offline tests: no model requests or real credentials."""
import contextlib
import fcntl
import http.client
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import runner
import server


class RunnerTests(unittest.TestCase):
    def test_rejects_commands_arguments_and_injection(self):
        for args in ([], ['status', 'x'], ['run', 'shell', 'haiku', 'gpt-5.6-luna'],
                     ['run', 'claude', 'haiku;id', 'gpt'], ['run', 'codex', '-x', 'gpt'],
                     ['run', 'both', 'haiku\nid', 'gpt'], ['run', 'both', 'haiku', 'gpt', 'x']):
            with self.subTest(args=args), self.assertRaises(ValueError):
                runner.validate(args)
        self.assertEqual(runner.validate(['run', 'both', 'haiku', 'gpt-5.6-luna']), 'run')

    def test_uses_cron_lock_and_skips_busy(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'STATE', Path(directory)):
            with (Path(directory) / 'run.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(runner.subprocess, 'run') as invoke:
                    result = runner.run('both', 'haiku', 'gpt-5.6-luna')
                    self.assertEqual(result['exit_code'], 75)
                    invoke.assert_not_called()

    def test_runs_both_after_first_failure_and_appends_original_log(self):
        fake = [subprocess.CompletedProcess([], 1, 'FAIL: HTTP 401\n'),
                subprocess.CompletedProcess([], 0, 'OK: ok\n')]
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'STATE', Path(directory)), \
                patch.object(runner.subprocess, 'run', side_effect=fake) as invoke:
            result = runner.run('both', 'haiku', 'gpt-5.6-luna')
            self.assertEqual(result['exit_code'], 1)
            self.assertEqual(invoke.call_count, 2)
            self.assertEqual(invoke.call_args_list[0].args[0],
                             ['/bin/bash', '/root/.local/bin/claude-ping', 'haiku'])
            self.assertNotIn('shell', invoke.call_args_list[0].kwargs)
            log = (Path(directory) / 'ai-ping.log').read_text()
            self.assertIn('FAIL: HTTP 401', log)
            self.assertIn('OK: ok', log)

    def test_tail_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'log'
            path.write_bytes(b'x' * (runner.MAX_LOG * 2) + b'end')
            value = runner.tail(path)
            self.assertEqual(len(value), runner.MAX_LOG)
            self.assertTrue(value.endswith('end'))


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(patch.object(server, 'SECRET', 'test-proxy-secret'))
        self.stack.enter_context(patch.object(server, 'PUBLIC_HOST', 'panel.example.com'))
        self.stack.enter_context(patch.object(server, 'JOB', None))
        self.stack.enter_context(patch.object(server, 'LAST_RUN', None))
        self.stack.enter_context(patch.object(server, 'AUTH_USER', 'ai-ping'))
        self.stack.enter_context(patch.object(server, 'AUTH_SALT', '00' * 16))
        self.stack.enter_context(patch.object(server, 'AUTH_HASH', server.password_hash('test-password', '00' * 16)))
        self.stack.enter_context(patch.object(server, 'SESSIONS', {'test-session': time.time() + 3600}))
        self.http = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.stack.close()

    def request(self, method, path, body=None, **overrides):
        headers = {'X-AI-Ping-Proxy': 'test-proxy-secret', 'X-AI-Ping': '1',
                   'Origin': 'https://' + server.PUBLIC_HOST, 'Content-Type': 'application/json',
                   'Cookie': server.COOKIE_NAME + '=test-session'}
        headers.update(overrides)
        connection = http.client.HTTPConnection(*self.http.server_address, timeout=2)
        connection.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = connection.getresponse()
        self.last_headers = dict(response.getheaders())
        data = response.read()
        connection.close()
        return response.status, json.loads(data) if 'application/json' in self.last_headers['Content-Type'] else data

    def test_public_login_does_not_send_basic_challenge_or_expose_logs(self):
        code, data = self.request('GET', '/', Cookie='')
        self.assertEqual(code, 200)
        self.assertIn(b'login-form', data)
        self.assertNotIn('WWW-Authenticate', self.last_headers)
        with patch.object(server, 'helper') as helper:
            self.assertEqual(self.request('GET', '/api/status', Cookie='')[0], 401)
            self.assertEqual(self.request('POST', '/api/run', {}, Cookie='')[0], 401)
            helper.assert_not_called()

    def test_login_cookie_logout_and_expiry(self):
        body = {'username': 'ai-ping', 'password': 'test-password'}
        self.assertEqual(self.request('POST', '/api/login', dict(body, password='wrong'), Cookie='')[0], 401)
        self.assertNotIn('Set-Cookie', self.last_headers)
        self.assertEqual(self.request('POST', '/api/login', body, Cookie='', Origin='https://evil.example')[0], 403)
        self.assertEqual(self.request('POST', '/api/login', body, Cookie='')[0], 200)
        cookie = self.last_headers['Set-Cookie']
        for flag in ('HttpOnly', 'Secure', 'SameSite=Strict', 'Path=/ai-ping/'):
            self.assertIn(flag, cookie)
        header = cookie.split(';', 1)[0]
        token = header.split('=', 1)[1]
        with patch.object(server, 'helper', return_value={'log': 'fixture'}):
            self.assertEqual(self.request('GET', '/api/status', Cookie=header)[0], 200)
            self.assertEqual(self.request('GET', '/api/status', Cookie=header + 'forged')[0], 401)
            server.SESSIONS[token] = time.time() - 1
            self.assertEqual(self.request('GET', '/api/status', Cookie=header)[0], 401)
            server.SESSIONS[token] = time.time() + 3600
            self.assertEqual(self.request('POST', '/api/logout', {}, Cookie=header)[0], 200)
            self.assertIn('Max-Age=0', self.last_headers['Set-Cookie'])
            self.assertEqual(self.request('GET', '/api/status', Cookie=header)[0], 401)

    def test_loopback_without_nginx_secret_rejected(self):
        self.assertEqual(self.request('GET', '/api/status', **{'X-AI-Ping-Proxy': ''})[0], 403)

    def test_csrf_and_invalid_payload_cannot_launch(self):
        body = {'provider': 'both', 'claude_model': 'haiku', 'codex_model': 'gpt-5.6-luna'}
        with patch.object(server, 'execute') as execute:
            for overrides in ({'Origin': 'https://evil.example'}, {'X-AI-Ping': ''},
                              {'Content-Type': 'text/plain'}):
                self.assertEqual(self.request('POST', '/api/run', body, **overrides)[0], 403)
            for value in ([], {}, dict(body, provider='shell'), dict(body, claude_model='haiku;id'),
                          dict(body, codex_model=['gpt']), dict(body, command='id')):
                self.assertEqual(self.request('POST', '/api/run', value)[0], 400)
            execute.assert_not_called()

    def test_launch_status_duplicate_and_cooldown(self):
        body = {'provider': 'codex', 'claude_model': 'haiku', 'codex_model': 'gpt-5.6-luna'}
        # A freshly booted host must allow the first run even before 10 seconds uptime.
        with patch.object(server, 'execute'), patch.object(server, 'helper', return_value={'log': 'fixture'}), \
                patch.object(server.time, 'monotonic', return_value=0.5):
            code, job = self.request('POST', '/api/run', body)
            self.assertEqual(code, 202)
            self.assertEqual(job['state'], 'running')
            self.assertEqual(self.request('POST', '/api/run', body)[0], 409)
            code, state = self.request('GET', '/api/status')
            self.assertEqual(state['job']['id'], job['id'])
            server.JOB['state'] = 'done'
            self.assertEqual(self.request('POST', '/api/run', body)[0], 429)

    def test_unknown_routes_and_helper_failure(self):
        self.assertEqual(self.request('GET', '/../../runner.py')[0], 404)
        self.assertEqual(self.request('POST', '/api/shell', {})[0], 404)
        with patch.object(server, 'helper', side_effect=ValueError()):
            self.assertEqual(self.request('GET', '/api/status')[0], 503)

    def test_management_auth_csrf_and_payload_forwarding(self):
        for path in ('/api/settings', '/api/accounts/import', '/api/accounts/delete'):
            with self.subTest(path=path), patch.object(server, 'helper', return_value={'exit_code': 0}) as helper:
                self.assertEqual(self.request('POST', path, {}, Cookie='')[0], 401)
                self.assertEqual(self.request('POST', path, {}, Origin='https://evil.example')[0], 403)
                helper.assert_not_called()
        body = {'provider': 'codex', 'name': 'Fixture',
                'authorization': {'tokens': {'access_token': 'fixture-' * 400}}}
        with patch.object(server, 'helper', return_value={'exit_code': 0, 'accounts': []}) as helper:
            self.assertEqual(self.request('POST', '/api/accounts/import', body)[0], 200)
            self.assertEqual(helper.call_args.args, ('manage',))
            self.assertEqual(helper.call_args.kwargs['payload']['operation'], 'import')
            self.assertEqual(helper.call_args.kwargs['payload']['authorization'], body['authorization'])
        with patch.object(server, 'helper', return_value={'exit_code': 75, 'output': 'Busy'}):
            self.assertEqual(self.request('POST', '/api/accounts/delete', {'id': 'fixture'})[0], 409)

    def test_helper_keeps_authorization_out_of_command_arguments(self):
        body = {'operation': 'import', 'authorization': {'access_token': 'never-in-argv'}}
        fake = subprocess.CompletedProcess([], 0, '{"exit_code":0}')
        with patch.object(server.subprocess, 'run', return_value=fake) as execute:
            server.helper('manage', payload=body)
            self.assertNotIn('never-in-argv', str(execute.call_args.args))
            self.assertIn('never-in-argv', execute.call_args.kwargs['input'])


if __name__ == '__main__':
    unittest.main()
