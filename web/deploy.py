#!/usr/bin/env python3
"""Install on a Linux server, validate and roll back on failure."""
import argparse
import datetime as dt
import grp
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

SOURCE = Path(__file__).resolve().parent
APP = Path('/opt/ai-ping-web')
CONFIG = Path('/etc/ai-ping-web')
FILES = ['store.py', 'server.py', 'runner.py', 'manage.js', 'index.html', 'app.css', 'app.js',
         'login.html', 'login.js', 'Import-WindowsAccounts.ps1', 'deploy.py', 'test_web.py',
         'test_profiles.py', 'test_deploy.py', 'ai-ping-web.service', 'ai-ping-run.sh', 'verify_live.py', 'README.md', '.gitignore']


def deployment_options(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='Existing HTTPS hostname (without scheme or path)')
    parser.add_argument('--vhost', required=True, type=Path, help='Existing Nginx TLS vhost file')
    options = parser.parse_args(arguments)
    if (len(options.host) > 253 or not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label)
                                         for label in options.host.split('.'))):
        parser.error('--host must be a hostname without scheme, port or path')
    if not options.vhost.is_absolute():
        parser.error('--vhost must be an absolute path')
    return options.host, options.vhost.resolve()


def include_panel(vhost, host):
    # Require one unambiguous server block rather than modify the wrong vhost.
    anchor = re.compile(r'^(\s*server_name\s+' + re.escape(host) + r'\s*;)[ \t]*$', re.MULTILINE)
    if len(anchor.findall(vhost)) != 1:
        raise ValueError('Expected exactly one server_name declaration for the HTTPS host')
    include = 'include /etc/nginx/snippets/ai-ping-web.conf;'
    if include in vhost:
        return vhost
    return anchor.sub(lambda match: match.group(1) + '\n    ' + include, vhost, count=1)


def command(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def atomic(path, content, mode=0o644, gid=0):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        temp = Path(out.name)
        out.write(content.encode('utf-8') if isinstance(content, str) else content)
    temp.chmod(mode)
    os.chown(temp, 0, gid)
    temp.replace(path)


def main(arguments=None):
    host, vhost_path = deployment_options(arguments)
    if os.geteuid() != 0:
        raise SystemExit('Run as root on the Linux server')
    for name in ('claude-ping', 'codex-ping', 'ai-ping-run', 'ai-ping.py'):
        if not (Path('/root/.local/bin') / name).is_file():
            raise SystemExit('Existing ai-ping installation required')
    vhost = include_panel(vhost_path.read_text(encoding='utf-8'), host)
    command('/usr/sbin/nginx', '-t')
    cron = subprocess.check_output(['/usr/bin/crontab', '-l'])
    if b"/root/.local/bin/ai-ping-run" not in cron:
        raise SystemExit('Expected ai-ping cron entry not found')
    command('/usr/bin/python3', '-m', 'unittest', '-v', 'test_web.py', cwd=SOURCE)
    command('/usr/bin/python3', '-m', 'unittest', '-v', 'test_profiles.py', cwd=SOURCE)
    command('/usr/bin/python3', '-m', 'unittest', '-v', 'test_deploy.py', cwd=SOURCE)
    command('/bin/sh', '-n', str(SOURCE / 'ai-ping-run.sh'))
    command('/usr/bin/python3', '-m', 'py_compile', str(SOURCE / 'server.py'), str(SOURCE / 'runner.py'))
    try:
        pwd.getpwnam('ai-ping-web')
    except KeyError:
        command('/usr/sbin/useradd', '--system', '--user-group', '--no-create-home',
                '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin', 'ai-ping-web')
    www_gid = grp.getgrnam('www-data').gr_gid
    CONFIG.mkdir(mode=0o755, exist_ok=True)
    access = CONFIG / 'access.json'
    settings = json.loads(access.read_text()) if access.is_file() else {
        'username': 'ai-ping', 'password': secrets.token_urlsafe(24),
        'proxy_secret': secrets.token_hex(32)}
    settings['url'] = 'https://' + host + '/ai-ping/'
    settings.setdefault('auth_salt', secrets.token_hex(16))
    from server import password_hash
    password_digest = password_hash(settings['password'], settings['auth_salt'])
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = Path('/var/backups/ai-ping-web') / stamp
    backup.mkdir(parents=True, mode=0o700)
    backup.parent.chmod(0o700)
    targets = [APP / name for name in FILES] + [Path('/root/.local/bin/ai-ping-run'),
        access, CONFIG / 'service.env',
        Path('/etc/nginx/snippets/ai-ping-web.conf'),
        Path('/etc/nginx/conf.d/ai-ping-web-rate.conf'),
        Path('/etc/sudoers.d/ai-ping-web'),
        Path('/etc/systemd/system/ai-ping-web.service'), vhost_path]
    saved = {}
    for index, target in enumerate(targets):
        saved[target] = (target.read_bytes(), target.stat()) if target.is_file() else None
        if saved[target]:
            shutil.copy2(target, backup / str(index))
    atomic(backup / 'manifest.json', json.dumps([str(t) for t in targets], indent=2), 0o600)
    active = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', 'ai-ping-web']).returncode == 0
    try:
        for name in FILES:
            atomic(APP / name, (SOURCE / name).read_bytes())
        atomic(access, json.dumps(settings, indent=2) + '\n', 0o600)
        atomic(CONFIG / 'service.env', 'AI_PING_PROXY_SECRET=' + settings['proxy_secret'] +
               '\nAI_PING_PUBLIC_HOST=' + host + '\nAI_PING_AUTH_USER=' + settings['username'] +
               '\nAI_PING_AUTH_SALT=' + settings['auth_salt'] +
               '\nAI_PING_AUTH_HASH=' + password_digest + '\n', 0o600)
        atomic(Path('/etc/sudoers.d/ai-ping-web'),
               'Defaults:ai-ping-web env_reset\n'
               'ai-ping-web ALL=(root) NOPASSWD: /usr/bin/python3 /opt/ai-ping-web/runner.py status, '
               '/usr/bin/python3 /opt/ai-ping-web/runner.py run *, '
               '/usr/bin/python3 /opt/ai-ping-web/runner.py manage\n', 0o440)
        atomic(Path('/etc/systemd/system/ai-ping-web.service'),
               (SOURCE / 'ai-ping-web.service').read_bytes())
        atomic(Path('/etc/nginx/conf.d/ai-ping-web-rate.conf'),
               'limit_req_zone $binary_remote_addr zone=ai_ping_web:1m rate=5r/s;\n')
        snippet = '''location = /ai-ping { return 302 /ai-ping/; }
location ^~ /ai-ping/ {
    limit_req zone=ai_ping_web burst=20 nodelay;
    limit_req_status 429;
    client_max_body_size 32k;
    client_body_timeout 5s;
    proxy_connect_timeout 2s;
    proxy_read_timeout 15s;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Authorization "";
    proxy_set_header X-AI-Ping-Proxy "PROXY_SECRET";
    proxy_pass http://127.0.0.1:18082/;
    add_header Referrer-Policy no-referrer always;
    add_header X-Content-Type-Options nosniff always;
    access_log off;
}
'''.replace('PROXY_SECRET', settings['proxy_secret'])
        atomic(Path('/etc/nginx/snippets/ai-ping-web.conf'), snippet, 0o640, www_gid)
        atomic(vhost_path, vhost)
        command('/usr/sbin/visudo', '-cf', '/etc/sudoers.d/ai-ping-web')
        # Cron keeps its existing every-minute entry; only its backed-up wrapper changes.
        atomic(Path('/root/.local/bin/ai-ping-run'), (SOURCE / 'ai-ping-run.sh').read_bytes(), 0o700)
        command('/usr/sbin/nginx', '-t')
        command('/usr/bin/systemd-analyze', 'verify', '/etc/systemd/system/ai-ping-web.service')
        command('/usr/bin/systemctl', 'daemon-reload')
        command('/usr/bin/systemctl', 'enable', '--now', 'ai-ping-web')
        if active:
            command('/usr/bin/systemctl', 'restart', 'ai-ping-web')
        for attempt in range(20):
            try:
                request = urllib.request.Request('http://127.0.0.1:18082/health',
                            headers={'X-AI-Ping-Proxy': settings['proxy_secret']})
                with urllib.request.urlopen(request, timeout=3) as response:
                    state = json.load(response)
                if not state.get('ready'):
                    raise RuntimeError('Backend did not become ready')
                break
            except (urllib.error.URLError, OSError):
                if attempt == 19:
                    raise
                time.sleep(.25)
        command('/usr/bin/systemctl', 'reload', 'nginx')
        # nginx reload signals the master asynchronously; an old worker can
        # briefly serve its previous Basic challenge before the new one is ready.
        for attempt in range(20):
            try:
                with urllib.request.urlopen(settings['url'], timeout=15) as response:
                    assert response.status == 200 and response.headers.get('WWW-Authenticate') is None
                    assert b'login-form' in response.read()
                break
            except (urllib.error.HTTPError, AssertionError):
                if attempt == 19:
                    raise
                time.sleep(.25)
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        request = urllib.request.Request(settings['url'] + 'api/login',
                    json.dumps({'username': settings['username'], 'password': settings['password']}).encode(),
                    {'Content-Type': 'application/json', 'X-AI-Ping': '1', 'Origin': 'https://' + host})
        with opener.open(request, timeout=15) as response:
            assert json.load(response).get('ok')
        with opener.open(settings['url'] + 'api/status', timeout=15) as response:
            state = json.load(response)
            assert all(v['authorized'] for v in state['providers'].values())
        assert subprocess.check_output(['/usr/bin/crontab', '-l']) == cron, 'Cron changed unexpectedly'
        print(json.dumps({'url': settings['url'], 'username': settings['username'],
                          'password': settings['password'], 'backup': str(backup),
                          'cron_sha256': hashlib.sha256(cron).hexdigest()}, ensure_ascii=False))
    except BaseException:
        for target, original in saved.items():
            if original:
                data, stat = original
                atomic(target, data, stat.st_mode & 0o777, stat.st_gid)
            else:
                target.unlink(missing_ok=True)
        subprocess.run(['/usr/bin/systemctl', 'daemon-reload'])
        if active:
            subprocess.run(['/usr/bin/systemctl', 'restart', 'ai-ping-web'])
        else:
            subprocess.run(['/usr/bin/systemctl', 'disable', '--now', 'ai-ping-web'])
        if subprocess.run(['/usr/sbin/nginx', '-t']).returncode == 0:
            subprocess.run(['/usr/bin/systemctl', 'reload', 'nginx'])
        raise


if __name__ == '__main__':
    main()
