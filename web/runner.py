#!/usr/bin/env python3
"""Root helper: only existing ai-ping commands and their shared log/lock."""
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
from zoneinfo import ZoneInfo

from store import ACCOUNT_ID, MODEL, Store

BIN = Path('/root/.local/bin')
STATE = Path('/root/.local/state/ai-ping')
MAX_LOG = 65536


def tail(path):
    try:
        with path.open('rb') as source:
            source.seek(max(0, path.stat().st_size - MAX_LOG))
            return source.read(MAX_LOG).decode('utf-8', errors='replace')
    except FileNotFoundError:
        return ''


def status():
    store = Store(STATE, BIN)
    settings = store.settings()
    return {
        'log': tail(STATE / 'ai-ping.log'),
        'schedule': settings['times'], 'timezone': settings['timezone'],
        'settings': settings, 'accounts': store.accounts(), 'next_run': store.next_run(),
        'providers': {p: {'installed': (BIN / (p + '-ping')).is_file(),
                         'authorized': (STATE / 'credentials' / (p + '.json')).is_file()}
                      for p in ('claude', 'codex')},
    }


def validate(arguments):
    if len(arguments) == 1 and arguments[0] in ('status', 'manage', 'scheduled', 'now'):
        return arguments[0]
    if (len(arguments) in (4, 6) and arguments[0] == 'run'
            and arguments[1] in ('both', 'claude', 'codex')
            and all(isinstance(m, str) and MODEL.fullmatch(m) for m in arguments[2:4])
            and all(isinstance(i, str) and ACCOUNT_ID.fullmatch(i) for i in arguments[4:])):
        return 'run'
    raise ValueError('Разрешены только Claude Ping и Codex Ping с корректным именем модели.')


def run(provider, claude_model, codex_model, claude_account='server-claude', codex_account='server-codex'):
    store = Store(STATE, BIN)
    commands = [('claude', claude_model, claude_account), ('codex', codex_model, codex_account)]
    commands = [item for item in commands if provider == 'both' or item[0] == provider]
    for name, _model, identifier in commands:
        store.account(identifier, name)
    return run_commands(commands, store)


def run_commands(commands, store, source='WEB', slot=None):
    with (STATE / 'run.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'exit_code': 75, 'output': 'Уже выполняется ai-ping по расписанию или из веб-панели.'}
        if slot:
            from store import read_json
            store.prepare()
            if read_json(store.root / 'last-scheduled.json', {}).get('slot') == slot:
                return {'exit_code': 0, 'skipped': True}
            store.atomic(store.root / 'last-scheduled.json', {'slot': slot}, backup=False)
        settings = store.settings()
        output, code = [], 0
        with (STATE / 'ai-ping.log').open('a', encoding='utf-8') as log:
            stamp = dt.datetime.now(ZoneInfo(settings['timezone'])).isoformat(timespec='seconds')
            log.write('\n[' + source + ' ' + stamp + ']\n')
            log.flush()
            for name, model, identifier in commands:
                account = store.account(identifier, name)
                home = '/root' if account['builtin'] else str(store.root / 'accounts' / identifier)
                env = {'HOME': home, 'TZ': settings['timezone'], 'LANG': 'C.UTF-8',
                       'PATH': '/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'}
                heading = '=== ' + name + '-ping ' + model + ' · ' + account['name'] + ' ===\n'
                try:
                    result = subprocess.run(
                        ['/bin/bash', str(BIN / (name + '-ping')), model],
                        env=env, cwd='/tmp', stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, encoding='utf-8', errors='replace', timeout=100,
                        check=False)
                    text = result.stdout[:MAX_LOG]
                    if result.returncode:
                        code = 1
                except subprocess.TimeoutExpired:
                    text, code = 'FAIL: превышено время ожидания (100 секунд).\n', 1
                except OSError:
                    text, code = 'FAIL: не удалось запустить установленную команду.\n', 1
                output.append(heading + text)
                log.write(heading + text + '\n')
                log.flush()
        return {'exit_code': code, 'output': '\n'.join(output)}


def scheduled(now=None, immediate=False):
    store = Store(STATE, BIN)
    settings = store.settings()
    now = now or dt.datetime.now(ZoneInfo(settings['timezone']))
    if not immediate and (not settings['enabled'] or now.strftime('%H:%M') not in settings['times']):
        return {'exit_code': 0, 'skipped': True}
    selected = settings['scheduled_accounts']
    if immediate and not selected:
        selected = list(settings['default_accounts'].values())
    if not selected:
        return {'exit_code': 0, 'skipped': True}
    commands = []
    for identifier in selected:
        account = store.account(identifier)
        commands.append((account['provider'], settings['models'][account['provider']], identifier))
    slot = None if immediate else settings['timezone'] + ':' + now.strftime('%Y-%m-%dT%H:%M')
    return run_commands(commands, store, 'MANUAL' if immediate else 'SCHEDULE', slot)


def manage(data):
    store = Store(STATE, BIN)
    store.prepare()
    if not isinstance(data, dict):
        raise ValueError('Некорректный запрос управления.')
    operation = data.get('operation')
    with (store.root / 'settings.lock').open('a') as config_lock:
        fcntl.flock(config_lock, fcntl.LOCK_EX)
        if operation == 'settings' and set(data) == {'operation', 'settings'}:
            store.save_settings(data['settings'])
        elif operation in ('import', 'delete'):
            with (STATE / 'run.lock').open('a') as run_lock:
                try:
                    fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return {'exit_code': 75, 'output': 'Сейчас выполняется пинг. Обновите аккаунты после завершения.'}
                if operation == 'import':
                    account = store.import_account({k: v for k, v in data.items() if k != 'operation'})
                elif set(data) == {'operation', 'id'} and isinstance(data['id'], str):
                    store.delete_account(data['id'])
                else:
                    raise ValueError('Некорректный запрос аккаунта.')
        else:
            raise ValueError('Неизвестная операция управления.')
    result = {'exit_code': 0, 'settings': store.settings(), 'accounts': store.accounts()}
    if operation == 'import':
        result['account'] = account
    return result


def main(arguments):
    os.umask(0o077)
    action = None
    try:
        action = validate(arguments)
        if action == 'status':
            value = status()
        elif action == 'manage':
            raw = sys.stdin.read(32769)
            if len(raw.encode('utf-8')) > 32768:
                raise ValueError('Файл авторизации слишком большой.')
            value = manage(json.loads(raw))
        elif action in ('scheduled', 'now'):
            value = scheduled(immediate=action == 'now')
        else:
            value = run(*arguments[1:])
    except (ValueError, OSError, TypeError, KeyError) as error:
        # Do not include file contents, credentials or subprocess stderr.
        value = {'exit_code': 1, 'output': str(error) if isinstance(error, ValueError)
                 else 'Не удалось прочитать состояние ai-ping.'}
    if action != 'scheduled' or not value.get('skipped'):
        print(json.dumps(value, ensure_ascii=False))
    return value.get('exit_code', 0)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
