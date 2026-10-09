"""Root-owned settings and account profiles; never returns authorization tokens."""
import base64
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import tempfile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MODEL = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,99}\Z')
ACCOUNT_ID = re.compile(r'(?:server-(?:claude|codex)|[a-f0-9]{16})\Z')
TIME = re.compile(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]\Z')
MAX_ACCOUNTS = 12


def normalize_authorization(binary_dir, provider, value):
    # Reuse the installed ai-ping importer: it strips refresh tokens/API keys.
    spec = importlib.util.spec_from_file_location('installed_ai_ping', binary_dir / 'ai-ping.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        return module.authorization_data(provider, value)
    except (ValueError, TypeError, KeyError, AttributeError):
        raise ValueError('Файл не содержит корректную авторизацию выбранного сервиса.') from None


def read_json(path, default=None):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return default


def claims(token):
    try:
        part = token.split('.')[1]
        value = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
        return value if isinstance(value, dict) else {}
    except (ValueError, IndexError, TypeError, AttributeError):
        return {}


def display_metadata(provider, value):
    tokens = value.get('claudeAiOauth' if provider == 'claude' else 'tokens', value)
    email, expires = None, None
    if isinstance(tokens, dict):
        email = claims(tokens.get('id_token', '')).get('email')
        if not isinstance(email, str) or not re.fullmatch(r'[^@\s\x00-\x1f\x7f]+@[^@\s\x00-\x1f\x7f]+', email):
            email = None
        expires = (tokens.get('expiresAt', 0) / 1000 if isinstance(tokens.get('expiresAt'), (int, float))
                   else claims(tokens.get('access_token', '')).get('exp'))
        if not isinstance(expires, (int, float)) or not 0 < expires < 32503680000:
            expires = None
    return {'email': email, 'expires_at': expires}


class Store:
    def __init__(self, state, binary_dir):
        self.state = Path(state)
        self.binary_dir = Path(binary_dir)
        self.root = self.state / 'web'

    def prepare(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root.chmod(0o700)

    def atomic(self, path, value, backup=True):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if backup and path.is_file():
            directory = self.root / 'backups'
            directory.mkdir(mode=0o700, exist_ok=True)
            stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%f')
            saved = directory / (stamp + '-' + secrets.token_hex(4) + '-' + path.name)
            saved.write_bytes(path.read_bytes())
            saved.chmod(0o600)
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as target:
            temporary = Path(target.name)
            os.chmod(temporary, 0o600)
            json.dump(value, target, ensure_ascii=False)
            target.write('\n')
        temporary.replace(path)

    def registry(self):
        value = read_json(self.root / 'accounts.json', [])
        if not isinstance(value, list):
            raise ValueError('Повреждён список аккаунтов. Восстановите резервную копию.')
        return value

    def credential_path(self, identifier, provider):
        if not ACCOUNT_ID.fullmatch(identifier) or provider not in ('claude', 'codex'):
            raise ValueError('Некорректный аккаунт.')
        if identifier.startswith('server-'):
            if identifier != 'server-' + provider:
                raise ValueError('Аккаунт относится к другому сервису.')
            return self.state / 'credentials' / (provider + '.json')
        return self.root / 'accounts' / identifier / '.local/state/ai-ping/credentials' / (provider + '.json')

    def accounts(self):
        records = {f'server-{p}': {'id': f'server-{p}', 'provider': p,
                   'name': ('Claude' if p == 'claude' else 'Codex') + ' · сервер'} for p in ('claude', 'codex')}
        for entry in self.registry():
            if (not isinstance(entry, dict) or not isinstance(entry.get('id'), str)
                    or not ACCOUNT_ID.fullmatch(entry['id']) or entry.get('provider') not in ('claude', 'codex')):
                raise ValueError('Повреждён список аккаунтов.')
            records[entry['id']] = entry
        output = []
        for identifier, entry in records.items():
            provider = entry['provider']
            path = self.credential_path(identifier, provider)
            try:
                value = read_json(path, {})
                metadata = display_metadata(provider, value)
                metadata.update({k: entry[k] for k in ('email', 'expires_at') if entry.get(k) is not None})
                scopes = (value.get('claudeAiOauth') or {}).get('scopes', [])
                if not isinstance(scopes, list) or not all(isinstance(s, str) for s in scopes):
                    scopes = []
                token = value.get('claudeAiOauth' if provider == 'claude' else 'tokens', {})
                authorized = path.is_file() and isinstance(token, dict) and bool(token.get('accessToken' if provider == 'claude' else 'access_token'))
            except (ValueError, AttributeError, TypeError):
                metadata, scopes, authorized = {}, [], False
            output.append({'id': identifier, 'provider': provider, 'name': entry['name'],
                           'builtin': identifier.startswith('server-'), 'authorized': authorized,
                           'email': metadata.get('email'), 'expires_at': metadata.get('expires_at'),
                           'limits_available': provider == 'codex' or set(scopes) != {'user:inference'}})
        return output

    def account(self, identifier, provider=None):
        for entry in self.accounts():
            if entry['id'] == identifier and (provider is None or entry['provider'] == provider):
                return entry
        raise ValueError('Аккаунт не найден или относится к другому сервису.')

    def settings(self):
        default = {'enabled': True, 'timezone': 'Europe/Moscow',
                   'times': ['06:00', '11:01', '16:02', '21:03'],
                   'models': {'claude': 'haiku', 'codex': 'gpt-5.6-luna'},
                   'default_accounts': {'claude': 'server-claude', 'codex': 'server-codex'},
                   'scheduled_accounts': ['server-claude', 'server-codex']}
        return read_json(self.root / 'settings.json', default)

    def save_settings(self, value):
        keys = {'enabled', 'timezone', 'times', 'models', 'default_accounts', 'scheduled_accounts'}
        if not isinstance(value, dict) or set(value) != keys or not isinstance(value['enabled'], bool):
            raise ValueError('Некорректные настройки расписания.')
        try:
            if not isinstance(value['timezone'], str):
                raise ValueError()
            ZoneInfo(value['timezone'])
        except (ZoneInfoNotFoundError, ValueError, TypeError):
            raise ValueError('Укажите действующий часовой пояс, например Europe/Moscow.') from None
        times = value['times']
        if (not isinstance(times, list) or not 1 <= len(times) <= 24
                or not all(isinstance(t, str) and TIME.fullmatch(t) for t in times)
                or len(set(times)) != len(times)):
            raise ValueError('Укажите от 1 до 24 разных времён в формате ЧЧ:ММ.')
        models, defaults, selected = value['models'], value['default_accounts'], value['scheduled_accounts']
        if (not isinstance(models, dict) or set(models) != {'claude', 'codex'}
                or not all(isinstance(m, str) and MODEL.fullmatch(m) for m in models.values())
                or not isinstance(defaults, dict) or set(defaults) != {'claude', 'codex'}
                or not isinstance(selected, list) or len(selected) > MAX_ACCOUNTS
                or not all(isinstance(i, str) for i in selected) or len(set(selected)) != len(selected)):
            raise ValueError('Проверьте модели и выбранные аккаунты.')
        for provider, identifier in defaults.items():
            self.account(identifier, provider)
        for identifier in selected:
            self.account(identifier)
        if value['enabled'] and not selected:
            raise ValueError('Выберите хотя бы один аккаунт для расписания или отключите его.')
        value = dict(value, times=sorted(times))
        self.atomic(self.root / 'settings.json', value)
        return value

    def import_account(self, data):
        if set(data) - {'provider', 'name', 'authorization', 'id'} or not {'provider', 'name', 'authorization'} <= set(data):
            raise ValueError('Некорректный импорт аккаунта.')
        provider, name = data['provider'], data['name']
        if (provider not in ('claude', 'codex') or not isinstance(name, str) or not 1 <= len(name.strip()) <= 60
                or any(ord(c) < 32 or ord(c) == 127 for c in name)):
            raise ValueError('Выберите сервис и имя аккаунта (до 60 символов).')
        identifier = data.get('id')
        if identifier is not None:
            if not isinstance(identifier, str) or not ACCOUNT_ID.fullmatch(identifier):
                raise ValueError('Некорректный аккаунт.')
            self.account(identifier, provider)
        else:
            if len(self.accounts()) >= MAX_ACCOUNTS:
                raise ValueError('Достигнут предел: 12 аккаунтов.')
            identifier = secrets.token_hex(8)
        normalized = normalize_authorization(self.binary_dir, provider, data['authorization'])
        metadata = display_metadata(provider, data['authorization'])
        entry = {'id': identifier, 'provider': provider, 'name': name.strip(), **metadata}
        entries = [item for item in self.registry() if item['id'] != identifier]
        self.atomic(self.credential_path(identifier, provider), normalized)
        self.atomic(self.root / 'accounts.json', entries + [entry])
        return self.account(identifier)

    def delete_account(self, identifier):
        account = self.account(identifier)
        if account['builtin']:
            raise ValueError('Серверный аккаунт можно обновить или исключить из расписания.')
        settings = self.settings()
        settings['scheduled_accounts'] = [i for i in settings['scheduled_accounts'] if i != identifier]
        for provider in settings['default_accounts']:
            if settings['default_accounts'][provider] == identifier:
                settings['default_accounts'][provider] = 'server-' + provider
        if not settings['scheduled_accounts']:
            settings['enabled'] = False
        home = self.root / 'accounts' / identifier
        backups = self.root / 'backups'
        backups.mkdir(mode=0o700, exist_ok=True)
        if home.is_symlink() or home.resolve().parent != (self.root / 'accounts').resolve():
            raise ValueError('Некорректный путь аккаунта.')
        if home.exists():
            home.replace(backups / (identifier + '-' + secrets.token_hex(8)))
        self.atomic(self.root / 'accounts.json', [e for e in self.registry() if e['id'] != identifier])
        self.atomic(self.root / 'settings.json', settings)

    def next_run(self):
        settings = self.settings()
        if not settings['enabled'] or not settings['scheduled_accounts']:
            return None
        zone = ZoneInfo(settings['timezone'])
        now = dt.datetime.now(zone)
        for days in (0, 1):
            for value in sorted(settings['times']):
                hour, minute = map(int, value.split(':'))
                when = dt.datetime.combine(now.date() + dt.timedelta(days=days), dt.time(hour, minute), zone)
                if when > now:
                    return when.isoformat()
        return None
