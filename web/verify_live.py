#!/usr/bin/env python3
"""Explicit live check: makes exactly one ping of each provider via HTTPS."""
import hashlib
import http.cookiejar
import json
from pathlib import Path
import time
import urllib.error
import urllib.request


def main():
    settings = json.loads(Path('/etc/ai-ping-web/access.json').read_text())
    url = settings['url']
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    credential_hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                         Path('/root/.local/state/ai-ping/credentials').glob('*.json')}

    def request(path, body=None, authorize=True, origin=None):
        headers = {}
        if body is not None:
            headers.update({'Content-Type': 'application/json', 'X-AI-Ping': '1',
                            'Origin': origin or url.split('/ai-ping/')[0]})
        data = json.dumps(body).encode() if body is not None else None
        try:
            target = opener if authorize else urllib.request.build_opener()
            with target.open(urllib.request.Request(url + path, data, headers), timeout=15) as response:
                raw = response.read()
                assert response.headers.get('WWW-Authenticate') is None
                return response.status, json.loads(raw) if 'api/' in path else raw
        except urllib.error.HTTPError as error:
            return error.code, None

    assert request('')[0] == 200
    assert request('', authorize=False)[0] == 200
    assert request('api/status', authorize=False)[0] == 401
    assert request('api/login', {'username': settings['username'], 'password': 'wrong'})[0] == 401
    assert request('api/login', {'username': settings['username'], 'password': settings['password']})[0] == 200
    for asset in ('app.js', 'app.css'):
        assert request(asset)[0] == 200
    body = {'provider': 'both', 'claude_model': 'haiku', 'codex_model': 'gpt-5.6-luna'}
    assert request('api/run', body, origin='https://evil.example')[0] == 403
    assert request('api/run', dict(body, claude_model='haiku;id'))[0] == 400
    code, job = request('api/run', body)
    assert code == 202, (code, job)
    assert request('api/run', body)[0] == 409
    for attempt in range(110):
        time.sleep(2)
        code, state = request('api/status')
        assert code == 200
        if state['job']['state'] == 'done':
            break
    else:
        raise AssertionError('Ping did not finish')
    result = state['job']
    assert result['id'] == job['id']
    assert result['exit_code'] == 0, result
    assert result['output'].count('OK:') == 2, result
    assert 'model=haiku' in result['output'] and 'model=gpt-5.6-luna' in result['output']
    assert result['output'] in state['log'] or all(section in state['log'] for section in result['output'].split('\n\n=== '))
    for path, digest in credential_hashes.items():
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'Credentials changed'
    assert request('api/logout', {})[0] == 200
    assert request('api/status')[0] == 401
    print(json.dumps({'https': 'ok', 'authentication': 'ok', 'csrf': 'ok', 'validation': 'ok',
                      'both_pings': result, 'credential_files': 'unchanged'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
