#!/usr/bin/env python3
"""Small unprivileged web service with form login; Nginx owns TLS."""
import hashlib
import hmac
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import secrets
import threading
import time
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parent
SECRET = os.environ.get('AI_PING_PROXY_SECRET', '')
PUBLIC_HOST = os.environ.get('AI_PING_PUBLIC_HOST', '')
AUTH_USER = os.environ.get('AI_PING_AUTH_USER', '')
AUTH_SALT = os.environ.get('AI_PING_AUTH_SALT', '')
AUTH_HASH = os.environ.get('AI_PING_AUTH_HASH', '')
COOKIE_NAME = 'ai_ping_session'
SESSION_TTL = 8 * 3600
SESSIONS = {}
SESSION_LOCK = threading.Lock()
GUARD = threading.Lock()
JOB = None
LAST_RUN = None
STATIC = {'/': ('index.html', 'text/html; charset=utf-8'),
          '/app.css': ('app.css', 'text/css; charset=utf-8'),
          '/app.js': ('app.js', 'application/javascript; charset=utf-8'),
          '/manage.js': ('manage.js', 'application/javascript; charset=utf-8'),
          '/login.js': ('login.js', 'application/javascript; charset=utf-8'),
          '/Import-WindowsAccounts.ps1': ('Import-WindowsAccounts.ps1', 'application/octet-stream')}


def password_hash(password, salt):
    return hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), bytes.fromhex(salt), 200000).hex()


def session_cookie(token, max_age):
    return (COOKIE_NAME + '=' + token + '; Path=/ai-ping/; Max-Age=' + str(max_age)
            + '; HttpOnly; Secure; SameSite=Strict')


def helper(*arguments, payload=None):
    source = {'stdin': subprocess.DEVNULL} if payload is None else {'input': json.dumps(payload, ensure_ascii=False)}
    result = subprocess.run(
        ['/usr/bin/sudo', '-n', '/usr/bin/python3', str(ROOT / 'runner.py'), *arguments],
        **source, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding='utf-8', timeout=215, check=False)
    if len(result.stdout) > 180000:
        raise ValueError('Helper response too large')
    return json.loads(result.stdout)


def execute(job, provider, claude_model, codex_model, claude_account='server-claude', codex_account='server-codex'):
    try:
        result = helper('run', provider, claude_model, codex_model, claude_account, codex_account)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        result = {'exit_code': 1, 'output': 'Не удалось выполнить ai-ping. Проверьте службу ai-ping-web.'}
    with GUARD:
        job.update(result, state='done', finished_at=time.time())


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *_args):
        pass  # Auth headers, request bodies and command output never enter journals.

    def send(self, code, value, content_type='application/json; charset=utf-8', cookie=None):
        data = (json.dumps(value, ensure_ascii=False).encode('utf-8')
                if isinstance(value, dict) else value)
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        if cookie is not None:
            self.send_header('Set-Cookie', cookie)
        self.send_header('Content-Security-Policy',
                         "default-src 'self'; script-src 'self'; style-src 'self'; "
                         "object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        self.wfile.write(data)

    def authorized_proxy(self):
        if SECRET and hmac.compare_digest(self.headers.get('X-AI-Ping-Proxy', '').encode(), SECRET.encode()):
            return True
        self.send(403, {'error': 'Доступ разрешён только через Nginx.'})
        return False

    def session_token(self):
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get('Cookie', ''))
            token = cookie[COOKIE_NAME].value
        except (CookieError, KeyError):
            return None
        with SESSION_LOCK:
            expires = SESSIONS.get(token, 0)
            if expires > time.time():
                return token
            SESSIONS.pop(token, None)
        return None

    def authenticated(self):
        if self.session_token():
            return True
        # JSON 401 never invokes a browser-native authentication dialog.
        self.send(401, {'error': 'Сессия завершилась. Войдите в панель снова.'})
        return False

    def login(self, data):
        if (set(data) != {'username', 'password'}
                or not all(isinstance(v, str) for v in data.values())
                or len(data['username']) > 100 or len(data['password']) > 256):
            return self.send(400, {'error': 'Введите логин и пароль.'})
        candidate = password_hash(data['password'], AUTH_SALT)
        if (not hmac.compare_digest(data['username'].encode(), AUTH_USER.encode())
                or not hmac.compare_digest(candidate, AUTH_HASH)):
            return self.send(401, {'error': 'Неверный логин или пароль.'})
        token = secrets.token_hex(32)
        with SESSION_LOCK:
            now = time.time()
            for expired in [key for key, expiry in SESSIONS.items() if expiry <= now]:
                del SESSIONS[expired]
            if len(SESSIONS) >= 64:
                del SESSIONS[min(SESSIONS, key=SESSIONS.get)]
            SESSIONS[token] = now + SESSION_TTL
        self.send(200, {'ok': True}, cookie=session_cookie(token, SESSION_TTL))

    def do_GET(self):
        if not self.authorized_proxy():
            return
        path = urlsplit(self.path).path
        if path == '/health':
            return self.send(200, {'ready': True})
        if path == '/' and not self.session_token():
            return self.send(200, (ROOT / 'login.html').read_bytes(), 'text/html; charset=utf-8')
        if path not in ('/app.css', '/login.js') and not self.authenticated():
            return
        if path in STATIC:
            filename, mime = STATIC[path]
            return self.send(200, (ROOT / filename).read_bytes(), mime)
        if path == '/api/status':
            try:
                value = helper('status')
                with GUARD:
                    value['job'] = dict(JOB) if JOB else None
                return self.send(200, value)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                return self.send(503, {'error': 'Не удалось прочитать журнал ai-ping.'})
        self.send(404, {'error': 'Страница не найдена.'})

    def do_POST(self):
        global JOB, LAST_RUN
        if not self.authorized_proxy():
            return
        path = urlsplit(self.path).path
        if path not in ('/api/run', '/api/login', '/api/logout', '/api/settings',
                        '/api/accounts/import', '/api/accounts/delete'):
            return self.send(404, {'error': 'Команда не найдена.'})
        # Require a same-origin JSON request and a non-simple header against CSRF.
        if (self.headers.get('Origin') != 'https://' + PUBLIC_HOST
                or self.headers.get('X-AI-Ping') != '1'
                or self.headers.get('Content-Type', '').split(';')[0] != 'application/json'):
            return self.send(403, {'error': 'Запрос должен быть отправлен из веб-панели.'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 1 <= size <= (32768 if path == '/api/accounts/import' else 4096):
                raise ValueError()
            data = json.loads(self.rfile.read(size))
            if not isinstance(data, dict):
                raise ValueError()
        except (ValueError, UnicodeError):
            return self.send(400, {'error': 'Некорректный запрос.'})
        if path == '/api/login':
            return self.login(data)
        if not self.authenticated():
            return
        if path == '/api/logout':
            token = self.session_token()
            with SESSION_LOCK:
                SESSIONS.pop(token, None)
            return self.send(200, {'ok': True}, cookie=session_cookie('', 0))
        if path in ('/api/settings', '/api/accounts/import', '/api/accounts/delete'):
            operation = {'/api/settings': 'settings', '/api/accounts/import': 'import',
                         '/api/accounts/delete': 'delete'}[path]
            payload = {'operation': 'settings', 'settings': data} if operation == 'settings' else {**data, 'operation': operation}
            try:
                result = helper('manage', payload=payload)
                if result.get('exit_code', 0):
                    return self.send(409 if result['exit_code'] == 75 else 400,
                                     {'error': result.get('output', 'Не удалось сохранить изменения.')})
                return self.send(200, result)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                return self.send(503, {'error': 'Не удалось сохранить изменения. Повторите попытку.'})
        try:
            required = {'provider', 'claude_model', 'codex_model'}
            if not required <= set(data) or set(data) - required - {'claude_account', 'codex_account'}:
                raise ValueError()
            arguments = [data['provider'], data['claude_model'], data['codex_model']]
            arguments += [data.get('claude_account', 'server-claude'), data.get('codex_account', 'server-codex')]
            if not all(isinstance(a, str) for a in arguments):
                raise ValueError()
            # Duplicate validation at the privilege boundary is intentional.
            import runner
            runner.validate(['run', *arguments])
        except (ValueError, TypeError, KeyError):
            return self.send(400, {'error': 'Укажите сервис и корректные имена моделей.'})
        with GUARD:
            if JOB and JOB['state'] == 'running':
                return self.send(409, {'error': 'Пинг уже выполняется. Дождитесь результата.'})
            if LAST_RUN is not None and time.monotonic() - LAST_RUN < 10:
                return self.send(429, {'error': 'Повторный запуск доступен через 10 секунд.'})
            LAST_RUN = time.monotonic()
            JOB = {'id': uuid.uuid4().hex, 'state': 'running', 'provider': data['provider'],
                   'started_at': time.time(), 'output': ''}
            threading.Thread(target=execute, args=(JOB, *arguments), daemon=True).start()
            value = dict(JOB)
        self.send(202, value)


if __name__ == '__main__':
    if not SECRET or not PUBLIC_HOST or not AUTH_USER or len(AUTH_SALT) != 32 or len(AUTH_HASH) != 64:
        raise SystemExit('Proxy secret and authentication must be configured')
    ThreadingHTTPServer(('127.0.0.1', 18082), Handler).serve_forever()
