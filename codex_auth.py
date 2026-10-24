"""Dedicated Linux Codex login; the official CLI owns OAuth and token rotation."""
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from contextlib import contextmanager

VERSION = '0.163.0'
SHA256 = 'beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4'


class AuthError(Exception):
    pass


def home():
    return Path.home() / '.local/state/ai-ping/codex'


def auth_path():
    return home() / 'auth.json'


def binary():
    return Path.home() / '.local/lib/ai-ping/codex'


def active():
    return not os.environ.get('CODEX_HOME') and auth_path().is_file()


def read_auth():
    with auth_path().open(encoding='utf-8') as source:
        value = json.load(source)
    tokens = value['tokens']
    if not tokens.get('access_token') or not tokens.get('refresh_token') or not tokens.get('account_id'):
        raise AuthError('Incomplete server login; run ai-ping.py --codex-login')
    return value


def expiry(value):
    part = value['tokens']['access_token'].split('.')[1]
    return float(json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))['exp'])


@contextmanager
def locked():
    import fcntl
    home().mkdir(parents=True, exist_ok=True, mode=0o700)
    home().chmod(0o700)
    with (home() / 'auth.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        # Bound waiting: a second ping must not hang behind an interactive login.
        deadline = time.monotonic() + 10
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise AuthError('Codex authorization is busy; retry after login or refresh completes')
                time.sleep(0.1)
        yield


def environment():
    return dict(os.environ, CODEX_HOME=str(home()))


def refresh():
    """Force OAuth renewal without starting a model turn or loading tools."""
    with subprocess.Popen([str(binary()), 'app-server'], env=environment(), cwd=str(home()),
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL) as process:
        pending = b''
        deadline = time.monotonic() + 45

        def send(message):
            process.stdin.write((json.dumps(message) + '\n').encode())
            process.stdin.flush()

        def receive(identifier):
            nonlocal pending
            while time.monotonic() < deadline:
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    event = json.loads(line)
                    if event.get('id') == identifier:
                        if 'error' in event:
                            raise AuthError('Codex refresh failed; run ai-ping.py --codex-login if the session was revoked')
                        return event['result']
                ready, _, _ = select.select([process.stdout], [], [], max(0, deadline-time.monotonic()))
                if ready:
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data:
                        raise AuthError('Codex auth manager stopped')
                    pending += data
                    if len(pending) > 1048576:
                        raise AuthError('Codex auth response too large')
            raise AuthError('Codex refresh timed out')

        try:
            send({'id': 1, 'method': 'initialize', 'params': {
                'clientInfo': {'name': 'ai_ping', 'version': '1.0'}}})
            receive(1)
            send({'method': 'initialized', 'params': {}})
            send({'id': 2, 'method': 'account/read', 'params': {'refreshToken': True}})
            if (receive(2).get('account') or {}).get('type') != 'chatgpt':
                raise AuthError('ChatGPT server login required')
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def ensure_fresh(force=False):
    with locked():
        value = read_auth()
        account = value['tokens']['account_id']
        if force or expiry(value) < time.time() + 3600:
            refresh()
            value = read_auth()
        if value['tokens']['account_id'] != account or expiry(value) <= time.time() + 300:
            raise AuthError('Refreshed server authorization failed validation')
        auth_path().chmod(0o600)


def install_cli():
    if binary().is_file():
        return
    if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'AMD64'):
        raise AuthError('Automatic Codex CLI installation currently requires Linux x86_64')
    binary().parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    artifact = 'codex-x86_64-unknown-linux-musl'
    url = f'https://github.com/openai/codex/releases/download/rust-v{VERSION}/{artifact}.tar.gz'
    print(f'Installing official Codex CLI {VERSION} (one-time download)...', flush=True)
    with tempfile.TemporaryDirectory(dir=binary().parent) as directory:
        archive = Path(directory) / 'codex.tar.gz'
        digest = hashlib.sha256()
        with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as target:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
                target.write(block)
        if digest.hexdigest() != SHA256:
            raise AuthError('Codex download checksum mismatch; no binary installed')
        with tarfile.open(archive, 'r:gz') as source:
            members = [m for m in source.getmembers() if m.isfile() and Path(m.name).name == artifact]
            if len(members) != 1:
                raise AuthError('Invalid Codex release archive')
            staged = Path(directory) / 'codex'
            import shutil
            with source.extractfile(members[0]) as stream, staged.open('wb') as target:
                shutil.copyfileobj(stream, target)
            staged.chmod(0o755)
            staged.replace(binary())


def setup(relogin=False):
    """Return True only after a new login (the installer then verifies a ping)."""
    if os.environ.get('CODEX_HOME'):
        raise AuthError('Unset CODEX_HOME for the dedicated AI Ping server login')
    install_cli()
    with locked():
        (home() / 'config.toml').write_text('cli_auth_credentials_store = "file"\n', encoding='utf-8')
        if auth_path().exists() and not relogin:
            read_auth()
            return False
        print('Sign in to the server session using the URL and code below.', flush=True)
        result = subprocess.run([str(binary()), 'login', '--device-auth'], env=environment(),
                                cwd=str(home()), timeout=960, check=False)
        if result.returncode:
            raise AuthError('Codex login was not completed; rerun setup')
        read_auth()
        auth_path().chmod(0o600)
        return True
