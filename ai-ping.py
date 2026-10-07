#!/usr/bin/env python3
"""Linux ping implementation. Uses only the Python standard library."""
# Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT

import base64
import datetime as dt
import getpass
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import warnings


class PingError(Exception):
    pass


def read_json(path):
    with path.open(encoding="utf-8") as source:
        value = json.load(source)
    if not isinstance(value, dict):
        raise ValueError("Expected an object")
    return value


def auth_path(provider):
    imported = imported_auth_path(provider)
    if not shutil.which(provider) and imported.is_file():
        return imported
    if provider == "claude":
        return Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / ".credentials.json"
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "auth.json"


def imported_auth_path(provider):
    return Path.home() / ".local" / "state" / "ai-ping" / "credentials" / (provider + ".json")


def authorization_data(provider, value):
    """Keep only fields needed for requests, never refresh tokens or API keys."""
    key, access = ("claudeAiOauth", "accessToken") if provider == "claude" else ("tokens", "access_token")
    tokens = value.get(key, value) if isinstance(value, dict) else None
    if not isinstance(tokens, dict) or not isinstance(tokens.get(access), str):
        raise ValueError("Missing access token")
    if not re.fullmatch(r"[a-zA-Z0-9._~+/-]+=*", tokens[access]):
        raise ValueError("Invalid access token")
    if tokens[access].startswith("sk-") and not (provider == "claude" and tokens[access].startswith("sk-ant-oat")):
        raise ValueError("Expected subscription authorization, not an API key")
    fields = (access,) if provider == "claude" else (access, "account_id", "id_token")
    kept = {access: tokens[access]}
    for field in fields[1:]:
        token = tokens.get(field)
        if token not in (None, ""):
            if not isinstance(token, str) or not re.fullmatch(r"[a-zA-Z0-9._~+/-]+=*", token):
                raise ValueError("Invalid token field")
            kept[field] = token
    if provider == "claude" and "scopes" in tokens:
        scopes = tokens["scopes"]
        if not isinstance(scopes, list) or not all(isinstance(scope, str) for scope in scopes):
            raise ValueError("Invalid authorization scopes")
        kept["scopes"] = scopes
    return {key: kept}


def save_authorization(provider, value):
    path = imported_auth_path(provider)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    if os.name == "posix" and path.parent.stat().st_mode & 0o777 != 0o700:
        raise PingError("cannot restrict credential directory permissions; use a Linux home filesystem that supports chmod")
    # Replace atomically; an interrupted paste/write must not destroy old auth.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as target:
            temporary = Path(target.name)
            temporary.chmod(0o600)
            if os.name == "posix" and temporary.stat().st_mode & 0o777 != 0o600:
                raise PingError("cannot restrict credential file permissions; no token saved")
            json.dump(value, target)
            target.write("\n")
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_authorization(prompt):
    if os.name != "posix" or not os.isatty(sys.stdin.fileno()):
        return getpass.getpass(prompt)
    import termios
    descriptor = sys.stdin.fileno()
    original = termios.tcgetattr(descriptor)
    private = original[:]
    private[6] = original[6][:]
    # Linux canonical input truncates lines at 4095 bytes. Codex's copied JSON
    # can be longer; read it without canonical buffering or terminal echo.
    private[3] &= ~(termios.ICANON | termios.ECHO)
    private[6][termios.VMIN] = 1
    private[6][termios.VTIME] = 0
    try:
        termios.tcsetattr(descriptor, termios.TCSANOW, private)
        return getpass.getpass(prompt)
    finally:
        termios.tcsetattr(descriptor, termios.TCSADRAIN, original)


def setup_authorization(provider):
    providers = ("claude", "codex") if provider == "both" else (provider,)
    pending = []
    for name in providers:
        if shutil.which(name):
            continue
        existing = False
        try:
            authorization_data(name, read_json(auth_path(name)))
            existing = True
        except (OSError, ValueError, TypeError):
            pass
        if not sys.stdin.isatty():
            if existing:
                continue
            raise PingError(f"{name} CLI and authorization are missing; run setup in an interactive terminal to paste Windows credentials")
        print(f"\n{name} is not installed on Linux. Copy authorization from your Windows computer:")
        print("1. Open Start, type PowerShell and open it (administrator rights are not needed).")
        if name == "claude":
            print("2. For scheduled pings, run claude setup-token and approve access in the browser.")
            print("3. Copy the printed one-year token. It permits model requests; account limits are unavailable.")
            print("Alternatively, sign in with claude /login and copy the short-lived login JSON for account limits:")
            print("$aiPingAuthDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }; Get-Content -Raw -LiteralPath (Join-Path $aiPingAuthDir '.credentials.json') | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress | Set-Clipboard")
            print("Copied login JSON expires unless renewed. With Claude CLI on Linux, sign in there for automatic refresh.")
        else:
            print("2. Sign in there: run codex login with your ChatGPT account.")
            print("3. Paste this command into PowerShell and press Enter; it copies authorization to the clipboard:")
            print("$aiPingAuthDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }; Get-Content -Raw -LiteralPath (Join-Path $aiPingAuthDir 'auth.json') | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress | Set-Clipboard")
            print('If the file is missing, open .codex/config.toml in your Windows user folder with Notepad,')
            print('add cli_auth_credentials_store = "file", then run codex login again. If CODEX_HOME is set, use that folder instead.')
        print("4. Return to this Linux terminal, paste with Ctrl+Shift+V (or right-click) and press Enter.")
        print("The pasted text is hidden. Ctrl+C cancels. Do not send it to anyone or paste it into a chat.")
        if existing:
            print("Authorization already exists. Press Enter to keep it, or paste new text to replace the AI Ping copy.")
        while True:
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("error", getpass.GetPassWarning)
                    pasted = read_authorization(f"{name} authorization: ").strip()
            except (EOFError, KeyboardInterrupt, getpass.GetPassWarning):
                raise PingError("Authorization input cancelled or hidden input unavailable; no new credentials saved") from None
            if not pasted and existing:
                break
            try:
                value = ({"accessToken": pasted, "scopes": ["user:inference"]}
                         if name == "claude" and pasted.startswith("sk-ant-oat")
                         else json.loads(pasted))
                pending.append((name, authorization_data(name, value)))
                break
            except (ValueError, TypeError):
                print("Invalid authorization. Copy the complete text again; an API key cannot replace subscription authorization.")
    # Validate all selected providers before saving either one.
    for name, value in pending:
        save_authorization(name, value)
        print(f"OK: {name} authorization saved for your Linux user (file permissions: 600).")
    if pending:
        print("Imported tokens are not refreshed automatically. If they expire, create fresh authorization on Windows and re-run setup.")
    return 0


def codex_tokens():
    try:
        tokens = read_json(auth_path("codex"))["tokens"]
        if not isinstance(tokens, dict) or not tokens.get("access_token"):
            raise ValueError("No token")
        return tokens
    except (OSError, ValueError, KeyError, TypeError):
        raise PingError("cannot read ChatGPT token; run codex login or re-run ai-ping-setup.sh to import Windows authorization") from None


def claude_headers():
    try:
        data = authorization_data("claude", read_json(auth_path("claude")))
        return {"Authorization": "Bearer " + data["claudeAiOauth"]["accessToken"],
                "anthropic-beta": "oauth-2025-04-20"}
    except (OSError, ValueError, TypeError):
        raise PingError("cannot read Claude token; sign in with claude or re-run ai-ping-setup.sh to import Windows authorization") from None


def request(url, headers, body=None, timeout=30):
    agent = "ai-ping/1.0"
    if url.startswith("https://chatgpt.com/"):
        agent = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                 "(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36")
    headers = dict(headers, **{"User-Agent": agent})
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers)
    # Do not forward bearer credentials through redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    with urllib.request.build_opener(NoRedirect).open(req, timeout=timeout) as response:
        return response.read().decode("utf-8")


def run_cli(arguments, environment=None, timeout=120):
    cli = shutil.which(arguments[0])
    if not cli:
        raise PingError(f"{arguments[0]} not found in PATH, install its CLI")
    # An empty directory avoids picking up project instructions from /tmp.
    with tempfile.TemporaryDirectory(prefix="ai-ping-") as directory:
        if arguments[0] == "codex":
            arguments = arguments + ["--cd", directory]
        result = subprocess.run(
            [cli] + arguments[1:], cwd=directory, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", errors="replace", timeout=timeout, check=False,
        )
    if result.returncode:
        raise PingError(f"{arguments[0]} exit code {result.returncode}")
    return result.stdout


def claude_environment():
    return dict(os.environ, MAX_THINKING_TOKENS="0", CLAUDE_CODE_EFFORT_LEVEL="low", CLAUDE_CODE_SAFE_MODE="1")


def claude_ping(model):
    if not shutil.which("claude"):
        return claude_http_ping(model)
    output = run_cli([
        "claude", "-p", "Reply: ok", "--model", model,
        "--system-prompt", "Reply with one word.", "--tools", "",
        "--strict-mcp-config", "--safe-mode", "--effort", "low",
        "--max-turns", "1", "--no-session-persistence", "--output-format", "json",
    ], claude_environment())
    result = json.loads(output)
    if (result.get("type") != "result" or result.get("is_error")
            or result.get("subtype") != "success"):
        raise PingError("Claude Code did not return a successful result")
    return str(result.get("result", "")).strip(), result.get("usage"), False


def claude_http_ping(model):
    # CLI aliases are resolved here because the Messages API needs a model ID.
    models = {"haiku": "claude-haiku-4-5", "sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5"}
    api_model = models.get(model, model)
    if not api_model.startswith("claude-") or "[" in api_model:
        raise PingError("without Claude CLI, use haiku, sonnet, opus or a full Claude API model ID")
    body = {"model": api_model, "max_tokens": 16, "system": "Reply with one word.",
            "messages": [{"role": "user", "content": "Reply: ok"}],
            "tools": [], "thinking": {"type": "disabled"}}
    if api_model in ("claude-sonnet-5-5", "claude-opus-5-5"):
        body["output_config"] = {"effort": "low"}
    try:
        output = request("https://api.anthropic.com/v1/messages",
                         dict(claude_headers(), **{"anthropic-version": "2023-06-01"}), body, 60)
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise PingError("Claude token expired (HTTP 401); sign in on Windows and re-run ai-ping-setup.sh to paste fresh authorization") from None
        raise
    result = json.loads(output)
    content, usage = result.get("content"), result.get("usage")
    if (result.get("type") != "message" or result.get("stop_reason") != "end_turn"
            or not isinstance(content, list) or not isinstance(usage, dict)):
        raise PingError("Claude server did not return a completed message with usage")
    answer = "".join(block["text"] for block in content if block.get("type") == "text")
    if not answer.strip():
        raise PingError("No text in completed Claude response")
    return answer.strip(), usage, False


def codex_cli_ping(model):
    print("Falling back to codex exec (token refresh).")
    output = run_cli([
        "codex", "exec", "Reply: ok", "-m", model,
        "-c", "model_reasoning_effort=low", "--ignore-user-config",
        "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
        "--color", "never", "--json",
    ])
    usage = None
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") in ("turn.failed", "error"):
            raise PingError("codex exec did not return a successful turn")
        if event.get("type") == "turn.completed":
            usage = event.get("usage")
    if not isinstance(usage, dict):
        raise PingError("No completed Codex CLI turn with usage received")
    return "", usage, True


def codex_headers(tokens):
    headers = {"Authorization": "Bearer " + tokens["access_token"],
               "Origin": "https://chatgpt.com", "Referer": "https://chatgpt.com"}
    if tokens.get("account_id"):
        headers["chatgpt-account-id"] = tokens["account_id"]
    return headers


def codex_ping(model):
    headers = dict(codex_headers(codex_tokens()), Accept="text/event-stream")
    body = {
        "model": model, "instructions": "You are Codex.",
        "input": [{"type": "message", "role": "user",
                   "content": [{"type": "input_text", "text": "Reply: ok"}]}],
        "tools": [], "tool_choice": "auto", "parallel_tool_calls": False,
        "reasoning": {"effort": "low"}, "store": False, "stream": True,
    }
    try:
        output = request("https://chatgpt.com/backend-api/codex/responses", headers, body, 60)
    except urllib.error.HTTPError as error:
        if error.code == 401:
            if not shutil.which("codex"):
                raise PingError("Codex token expired (HTTP 401); sign in on Windows and re-run ai-ping-setup.sh to paste fresh authorization") from None
            print("Token expired (HTTP 401).")
            return codex_cli_ping(model)
        raise PingError(f"HTTP {error.code}") from None
    answer, usage = "", None
    for line in output.splitlines():
        if not line.startswith("data:"):
            continue
        try:
            event = json.loads(line[5:].strip())
        except ValueError:
            continue
        if event.get("type") == "response.output_text.done":
            answer = event.get("text", "")
        elif event.get("type") == "response.completed":
            usage = event.get("response", {}).get("usage")
        elif event.get("type") in ("response.failed", "response.incomplete", "error"):
            raise PingError("Codex server did not return a successful response")
    if not isinstance(usage, dict):
        raise PingError("No completed response with usage received")
    return str(answer).strip(), usage, False


def current_login(provider):
    try:
        if provider == "claude":
            if not shutil.which("claude"):
                return "unavailable"
            status = json.loads(run_cli(["claude", "auth", "status", "--json"], claude_environment(), 10))
            email = status.get("email") if status.get("loggedIn") is True else None
        else:
            token = codex_tokens().get("id_token", "")
            payload = token.split(".")[1]
            email = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))).get("email")
        if isinstance(email, str) and re.fullmatch(r"[^@\s\x00-\x1f\x7f]+@[^@\s\x00-\x1f\x7f]+", email):
            return email
    except (PingError, OSError, ValueError, IndexError, TypeError, AttributeError, subprocess.TimeoutExpired):
        pass
    return "unavailable"


def write_tokens(provider, usage):
    if not usage:
        print("  tokens: unavailable")
        return
    incoming, outgoing = usage.get("input_tokens"), usage.get("output_tokens")
    if provider == "claude":
        cached, written = usage.get("cache_read_input_tokens"), usage.get("cache_creation_input_tokens")
        values = [incoming, outgoing, cached, written]
        total = sum(values) if all(isinstance(n, (int, float)) for n in values) else None
        extra = f"cache_write={count(written)}  cached={count(cached)}"
    else:
        cached = (usage.get("input_tokens_details") or {}).get("cached_tokens", usage.get("cached_input_tokens"))
        reasoning = (usage.get("output_tokens_details") or {}).get("reasoning_tokens")
        total = usage.get("total_tokens")
        if total is None and incoming is not None and outgoing is not None:
            total = incoming + outgoing
        extra = f"cached={count(cached)}  reasoning={count(reasoning)}"
    print(f"  TOKENS\n  input={count(incoming)}  output={count(outgoing)}  total={count(total)}\n  {extra}")


def count(value):
    return "n/a" if value is None else str(value)


def write_window(window, name, provider):
    if provider == "codex":
        duration = window.get("limit_window_seconds")
        name = {18000: "5-hour", 604800: "weekly"}.get(duration, name)
    percent = window.get("utilization" if provider == "claude" else "used_percent")
    used, remaining, bar = "n/a", "n/a", "?" * 20
    if isinstance(percent, (int, float)) and math.isfinite(percent):
        used = f"{percent:g}%"
        remaining = f"{max(0, min(100, 100 - percent)):g}%"
        filled = round(max(0, min(100, percent)) / 5)
        bar = "#" * filled + "-" * (20 - filled)
    reset, countdown = "unknown", ""
    try:
        if provider == "claude":
            at = dt.datetime.fromisoformat(window["resets_at"].replace("Z", "+00:00"))
            if at.tzinfo is None:
                at = at.replace(tzinfo=dt.timezone.utc)
        else:
            value = window["reset_at"]
            if value <= 0:
                raise ValueError("Invalid reset")
            at = dt.datetime.fromtimestamp(value, dt.timezone.utc)
        at = at.astimezone()
        reset = at.strftime("%Y-%m-%d %H:%M:%S %z")
        seconds = int((at - dt.datetime.now(dt.timezone.utc)).total_seconds())
        days, seconds_in_day = divmod(max(0, seconds), 86400)
        hours, rest = divmod(seconds_in_day, 3600)
        minutes, seconds_left = divmod(rest, 60)
        countdown = f"in {days}d {hours:02}:{minutes:02}:{seconds_left:02}" if seconds > 0 else "reset due"
    except (KeyError, ValueError, TypeError, AttributeError, OverflowError, OSError):
        pass
    print(f"  {name:<9} [{bar}]  remaining={remaining}  used={used}\n            resets={reset}")
    if countdown:
        print(f"            {countdown}")
    print()


def write_limits(provider):
    try:
        if provider == "claude":
            tokens = authorization_data("claude", read_json(auth_path("claude")))["claudeAiOauth"]
            if set(tokens.get("scopes", [])) == {"user:inference"}:
                print("\n  LIMITS\n  unavailable (setup-token permits model requests only).")
                return
            headers = dict(claude_headers(), Accept="application/json")
            usage = json.loads(request("https://api.anthropic.com/api/oauth/usage", headers, timeout=10))
            windows = [(usage.get("five_hour"), "5-hour"), (usage.get("seven_day"), "weekly")]
        else:
            headers = dict(codex_headers(codex_tokens()), Accept="application/json")
            usage = json.loads(request("https://chatgpt.com/backend-api/wham/usage", headers))
            limits = usage.get("rate_limit") or {}
            windows = [(limits.get("primary_window"), "primary"), (limits.get("secondary_window"), "secondary")]
        plan = usage.get("plan_type") if provider == "codex" else None
        label = f"  plan={plan}" if isinstance(plan, str) and re.fullmatch(r"[a-zA-Z0-9_-]+", plan) else ""
        print("\n  LIMITS" + label)
        found = False
        for window, name in windows:
            if isinstance(window, dict) and window:
                write_window(window, name, provider)
                found = True
        if not found:
            print("  limits: unavailable (no quota windows returned)")
    except urllib.error.HTTPError as error:
        print(f"WARN: limits unavailable (HTTP {error.code}).")
    except (PingError, OSError, ValueError, KeyError, TypeError, AttributeError):
        print("WARN: limits unavailable (network, authentication or response error).")


def main(arguments):
    if len(arguments) == 2 and arguments[0] == "--setup-auth" and arguments[1] in ("both", "claude", "codex"):
        try:
            return setup_authorization(arguments[1])
        except PingError as error:
            print(f"FAIL: {error}", file=sys.stderr)
        except OSError:
            print("FAIL: cannot save authorization for this Linux user", file=sys.stderr)
        return 1
    if not 1 <= len(arguments) <= 2 or arguments[0] not in ("claude", "codex"):
        print("Usage: claude-ping [model] / codex-ping [model]", file=sys.stderr)
        return 1
    provider = arguments[0]
    model = arguments[1] if len(arguments) == 2 else {"claude": "haiku", "codex": "gpt-5.6-luna"}[provider]
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._:/\[\]-]*", model):
        print("FAIL: invalid model name", file=sys.stderr)
        return 1
    try:
        answer, usage, fallback = {"claude": claude_ping, "codex": codex_ping}[provider](model)
        # Escape terminal controls in model output before printing or logging it.
        answer = re.sub(r"[\x00-\x1f\x7f]", "", answer)
        stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"\n[{stamp}] OK (cli)" if fallback else f"\n[{stamp}] OK: '{answer}'")
        print(f"  login={current_login(provider)}\n  model={model}")
        write_tokens(provider, usage)
        # Reload credentials here: a CLI may have refreshed them during the ping.
        write_limits(provider)
        return 0
    except PingError as error:
        print(f"FAIL: {error}", file=sys.stderr)
    except subprocess.TimeoutExpired:
        print("FAIL: CLI timed out", file=sys.stderr)
    except urllib.error.HTTPError as error:
        print(f"FAIL: HTTP {error.code}", file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        # Never expose raw HTTP bodies, CLI stderr or authentication data.
        print("FAIL: network, CLI or response error", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
