#!/usr/bin/env python3
"""Offline Ubuntu ping regression checks; never use real credentials or HTTP."""
import base64
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ubuntu_ping", ROOT / "ai-ping.py")
ping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ping)

CLAUDE_USAGE = {"input_tokens": 20, "output_tokens": 3,
                "cache_creation_input_tokens": 10, "cache_read_input_tokens": 50}
CODEX_USAGE = {"input_tokens": 20, "output_tokens": 3, "total_tokens": 23,
               "input_tokens_details": {"cached_tokens": 5},
               "output_tokens_details": {"reasoning_tokens": 1}}


class PingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix=".ubuntu-test-", dir=ROOT)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {
            "CLAUDE_CONFIG_DIR": str(self.directory / "claude"),
            "CODEX_HOME": str(self.directory / "codex"),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        for provider in ("claude", "codex"):
            ping.auth_path(provider).parent.mkdir()
        self.write_auth()
        self.reset = int((dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=5)).timestamp())

    def write_auth(self, access="offline-token", email="test@example.com"):
        payload = base64.urlsafe_b64encode(json.dumps({"email": email}).encode()).decode().rstrip("=")
        ping.auth_path("codex").write_text(json.dumps({"tokens": {
            "access_token": access, "account_id": "offline-account", "id_token": f"x.{payload}.x",
        }}), encoding="utf-8")
        ping.auth_path("claude").write_text(json.dumps({"claudeAiOauth": {"accessToken": access}}), encoding="utf-8")

    def limits(self, provider):
        if provider == "claude":
            at = dt.datetime.fromtimestamp(self.reset, dt.timezone.utc).isoformat()
            return {"five_hour": {"utilization": 12.5, "resets_at": at},
                    "seven_day": {"utilization": 35, "resets_at": at}}
        return {"plan_type": "plus", "rate_limit": {
            "primary_window": {"used_percent": 12, "reset_at": self.reset, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 35, "reset_at": self.reset, "limit_window_seconds": 604800},
        }}

    def events(self, usage=CODEX_USAGE):
        return "data: " + json.dumps({"type": "response.output_text.done", "text": "ok"}) + "\n" + \
            "data: " + json.dumps({"type": "response.completed", "response": {"usage": usage}}) + "\n"

    def cli(self, args, environment=None, timeout=120):
        if args[1:3] == ["auth", "status"]:
            return json.dumps({"loggedIn": True, "email": "test@example.com"})
        return json.dumps({"type": "result", "subtype": "success", "result": "ok", "usage": CLAUDE_USAGE})

    def execute(self, args, http=None, cli=None):
        provider = args[0]
        def response(url, headers, body=None, timeout=30):
            return self.events() if body is not None else json.dumps(self.limits(provider))
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                patch.object(ping, "request", side_effect=http or response) as request_mock, \
                patch.object(ping, "run_cli", side_effect=cli or self.cli) as cli_mock:
            code = ping.main(args)
        text = output.getvalue()
        self.assertNotIn("offline-token", text)
        return code, text, request_mock, cli_mock

    def test_default_and_explicit_models_and_limits(self):
        for provider, model in (("claude", "haiku"), ("claude", "sonnet"),
                                ("codex", "gpt-5.6-luna"), ("codex", "gpt-5.6-sol")):
            with self.subTest(provider=provider, model=model):
                args = [provider] if model in ("haiku", "gpt-5.6-luna") else [provider, model]
                code, output, http, cli = self.execute(args)
                self.assertEqual(code, 0)
                for value in ("OK: 'ok'", f"model={model}", "login=test@example.com", "5-hour", "weekly", "in 0d"):
                    self.assertIn(value, output)
                self.assertIn("total=83" if provider == "claude" else "total=23", output)
                reset = dt.datetime.fromtimestamp(self.reset).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
                self.assertIn(f"resets={reset}", output)
                if provider == "claude":
                    flags, environment = cli.call_args_list[0].args
                    self.assertEqual(flags[flags.index("--tools") + 1], "")
                    for flag in ("--safe-mode", "--strict-mcp-config", "--no-session-persistence"):
                        self.assertIn(flag, flags)
                    self.assertEqual(environment["MAX_THINKING_TOKENS"], "0")
                    self.assertEqual(environment["CLAUDE_CODE_EFFORT_LEVEL"], "low")
                else:
                    body = http.call_args_list[0].args[2]
                    self.assertEqual(body["model"], model)
                    self.assertEqual(body["tools"], [])
                    self.assertFalse(body["store"])
                    self.assertEqual(body["reasoning"], {"effort": "low"})

    def test_missing_authentication_and_invalid_json(self):
        for content in (None, "invalid", "{}", '{"tokens": {}}'):
            with self.subTest(content=content):
                path = ping.auth_path("codex")
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(content, encoding="utf-8")
                code, output, http, cli = self.execute(["codex"])
                self.assertEqual(code, 1)
                self.assertIn("codex login", output)
                http.assert_not_called()
                cli.assert_not_called()

    def test_401_fallback_refreshes_auth_and_requires_completed_turn(self):
        def http(url, headers, body=None, timeout=30):
            if body is not None:
                raise urllib.error.HTTPError(url, 401, "Unauthorized", {}, None)
            self.assertEqual(headers["Authorization"], "Bearer refreshed-offline-token")
            return json.dumps(self.limits("codex"))
        def cli(args, environment=None, timeout=120):
            self.assertIn("--ignore-user-config", args)
            self.assertIn("--ephemeral", args)
            self.assertEqual(args[args.index("--sandbox") + 1], "read-only")
            self.write_auth("refreshed-offline-token", "new@example.com")
            return json.dumps({"type": "turn.completed", "usage": CODEX_USAGE})
        code, output, _, _ = self.execute(["codex"], http, cli)
        self.assertEqual(code, 0)
        self.assertIn("OK (cli)", output)
        self.assertIn("login=new@example.com", output)
        for event in ({"type": "turn.failed"}, {"type": "thread.started"}):
            code, _, _, _ = self.execute(["codex"], http, lambda *a: json.dumps(event))
            self.assertEqual(code, 1)

    def test_http_errors_do_not_fallback_or_expose_body(self):
        for status in (403, 429, 500):
            code, output, _, cli = self.execute(["codex"], lambda *a: (_ for _ in ()).throw(
                urllib.error.HTTPError("offline", status, "secret server body", {}, None)))
            self.assertEqual(code, 1)
            self.assertIn(f"HTTP {status}", output)
            self.assertNotIn("secret server body", output)
            cli.assert_not_called()

    def test_failed_or_incomplete_stream(self):
        for content in ("data: invalid\n", self.events(None),
                        'data: {"type":"response.failed","response":{"error":{"message":"secret"}}}',
                        'data: {"type":"response.incomplete"}', 'data: {"type":"error","message":"secret"}'):
            code, output, _, _ = self.execute(["codex"], lambda *a: content)
            self.assertEqual(code, 1)
            self.assertNotIn("secret", output)

    def test_claude_cli_failures_and_missing_cli(self):
        for error in (ping.PingError("claude not found in PATH"), ping.PingError("claude exit code 9"),
                      subprocess.TimeoutExpired("claude", 120), ValueError("invalid JSON")):
            code, output, _, _ = self.execute(["claude"], cli=lambda *a: (_ for _ in ()).throw(error))
            self.assertEqual(code, 1)
            self.assertIn("FAIL:", output)
        with patch.object(ping.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ping.PingError, "not found in PATH"):
                ping.run_cli(["claude"])
            with self.assertRaisesRegex(ping.PingError, "not found in PATH"):
                ping.run_cli(["codex", "exec"])
        code, _, _, _ = self.execute(["claude"], cli=lambda *a: '{"type":"result","is_error":true}')
        self.assertEqual(code, 1)

    def test_optional_statistics_failures_keep_success(self):
        for provider in ("claude", "codex"):
            for status in (401, 429):
                def response(url, headers, body=None, timeout=30):
                    if body is not None:
                        return self.events()
                    raise urllib.error.HTTPError(url, status, "secret", {}, None)
                code, output, _, _ = self.execute([provider], response)
                self.assertEqual(code, 0)
                self.assertIn(f"WARN: limits unavailable (HTTP {status})", output)
        code, output, _, _ = self.execute(["claude"], lambda *a, **kw: "{}")
        self.assertEqual(code, 0)
        self.assertIn("no quota windows", output)

    def test_missing_optional_identity_and_statistics(self):
        self.write_auth(email="bad\nemail@example.com")
        code, output, _, _ = self.execute(["codex"])
        self.assertEqual(code, 0)
        self.assertIn("login=unavailable", output)
        code, output, _, _ = self.execute(["claude"], cli=lambda *a: json.dumps({
            "type": "result", "subtype": "success", "result": "ok"}))
        self.assertEqual(code, 0)
        self.assertIn("tokens: unavailable", output)
        self.assertIn("login=unavailable", output)

    def test_weekly_window_first_and_missing_reset(self):
        content = self.limits("codex")
        content["rate_limit"]["primary_window"] = content["rate_limit"].pop("secondary_window")
        content["rate_limit"]["primary_window"].pop("reset_at")
        code, output, _, _ = self.execute(["codex"], lambda *a: self.events() if len(a) > 2 else json.dumps(content))
        self.assertEqual(code, 0)
        self.assertIn("weekly", output)
        self.assertNotIn("5-hour", output)
        self.assertIn("resets=unknown", output)

    def test_invalid_arguments_send_no_requests(self):
        for args in (["claude", "bad model"], ["codex", "--help"], ["codex", "x", "y"], [], ["other"]):
            with patch.object(ping, "request") as http, patch.object(ping, "run_cli") as cli, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ping.main(args), 1)
                http.assert_not_called()
                cli.assert_not_called()

    def test_cli_runs_in_empty_directory_and_captures_stderr(self):
        def run(args, **kwargs):
            self.assertEqual(list(Path(kwargs["cwd"]).iterdir()), [])
            self.assertEqual(kwargs["stderr"], subprocess.PIPE)
            self.assertEqual(args[args.index("--cd") + 1], kwargs["cwd"])
            return subprocess.CompletedProcess(args, 0, "offline output", "")
        with patch.object(ping.tempfile, "tempdir", str(self.directory)), \
                patch.object(ping.shutil, "which", return_value="offline-cli"), \
                patch.object(ping.subprocess, "run", side_effect=run):
            self.assertEqual(ping.run_cli(["codex", "exec"]), "offline output")


if __name__ == "__main__":
    unittest.main(verbosity=2)
