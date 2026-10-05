![AI Ping — Claude Code + Codex](assets/readme-banner.svg)

<p align="center">
  <a href="#windows-requirements"><img alt="Windows" src="https://img.shields.io/badge/platform-Windows-0078D4?style=flat-square" /></a>
  <a href="#ubuntu"><img alt="Ubuntu" src="https://img.shields.io/badge/platform-Ubuntu-E95420?style=flat-square" /></a>
  <a href="#windows-requirements"><img alt="Windows PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square" /></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square" /></a>
</p>

<p align="center"><strong>English</strong> · <a href="README.ru.md">Русский</a></p>

# AI Ping

**Minimal requests to Claude Code and Codex on Windows and Ubuntu — with the current account, token usage, and quota reset times.**

AI Ping checks subscription access with short model requests and shows the current account email, request token counts, remaining 5-hour and weekly quotas, and server reset countdowns. Run it manually, through Windows Task Scheduler, or through Ubuntu cron to start an inactive usage window ahead of work.

[Quick start](#quick-start) · [Ubuntu](#ubuntu) · [Usage](#usage) · [Example output](#example-output) · [Scheduling](#scheduling) · [License](#license)

## Quick start

Choose the command for your terminal.

**PowerShell 5.1 / 7** — use this when your prompt starts with `PS`:

```powershell
$aiPingInstaller = Join-Path $env:TEMP 'ai-ping-install.bat'; curl.exe --fail --location --output $aiPingInstaller https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat; if ($? -and $LASTEXITCODE -eq 0) { & $aiPingInstaller }
```

**Command Prompt (`cmd.exe`):**

```bat
curl.exe --fail --location --output "%TEMP%\ai-ping-install.bat" https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat && call "%TEMP%\ai-ping-install.bat"
```

PowerShell uses `$env:TEMP` and `&`; cmd uses `%TEMP%` and `call`. The PowerShell command only launches the downloaded file when curl succeeds.

The installer saves a GitHub ZIP archive to disk, extracts it, and installs both commands into `%USERPROFILE%\.local\bin`. It adds that folder to your user `PATH` without duplicates and removes the temporary archive folder.

The MIT notice is installed beside the commands as `ai-ping-LICENSE.txt`.

**No Git or administrator access required.** Repeat the command to update. Open a new terminal when installation finishes:

```bat
claude-ping
codex-ping
```

<details>
<summary>Install from a clone or ZIP</summary>

```powershell
git clone https://github.com/dprytkov/ai-ping.git
cd ai-ping
.\ai-ping-setup.bat
```

Or [download the ZIP](https://github.com/dprytkov/ai-ping/archive/refs/heads/main.zip), extract it, and run `ai-ping-setup.bat`. Keep it beside both ping scripts and `LICENSE`.

To inspect the internet installer first, review [install.bat](install.bat). The downloaded launcher remains at `%TEMP%\ai-ping-install.bat` for inspection.

</details>

## Ubuntu

Install Python 3, cron, and the selected provider's CLI; sign in as the user who will run the scheduled pings. The scripts use Python's standard library, with no pip packages or jq.

```bash
sudo apt update
sudo apt install python3 cron util-linux curl tar
sudo systemctl enable --now cron
```

From a clone or extracted archive, run setup **without sudo**:

```bash
bash ai-ping-setup.sh --start 08:00 --provider both
```

Without options, setup asks for the first daily time and `both`, `claude`, or `codex` (defaults: `08:00`, `both`). Noninteractive runs use these defaults. `08:00` creates daily runs at **08:00, 13:00, 18:00, 23:00** in Ubuntu's local time zone. `07:30` creates **07:30, 12:30, 17:30, 22:30**. Runs never start after 23:00; an existing request may finish later. A missed run while the machine is off is skipped.

The internet launcher downloads and extracts the repository before calling the same setup:

```bash
curl --fail --location --proto '=https' --tlsv1.2 --output /tmp/ai-ping-install.sh https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.sh && bash /tmp/ai-ping-install.sh --start 08:00 --provider both
```

Setup installs `claude-ping`, `codex-ping`, the shared `ai-ping.py`, and `ai-ping-run` into `~/.local/bin`, plus `ai-ping-LICENSE.txt`. It adds a guarded PATH block to `.profile` and `.bashrc`; open a new Bash terminal afterward. Repeat setup to change the schedule or update scripts. It replaces only its marked block in your crontab, preserves other jobs, and sends no model requests during installation.

```bash
claude-ping sonnet
codex-ping gpt-5.6-sol
crontab -l
tail -n 40 ~/.local/state/ai-ping/ai-ping.log
```

Scheduled models can be set with `--claude-model sonnet --codex-model gpt-5.6-sol`. The runner records your installation-time PATH, `CLAUDE_CONFIG_DIR`, and `CODEX_HOME` if set, uses the same user's credentials, and prevents overlapping scheduled runs. Both providers are attempted even if one fails. It runs while signed out as long as cron and the machine are running. Logs may contain your account email. Use `crontab -e` and remove the `# BEGIN AI-PING` / `# END AI-PING` block to stop scheduling. [Detailed Ubuntu instructions](ai-ping.md#ubuntu).

## Windows requirements

- Windows with **Windows PowerShell 5.1** and an internet connection.
- `curl.exe` and `tar.exe` on `PATH` for the internet installer.
- The relevant CLI, signed in with a subscription account that supports your chosen model.
- Claude Code with `--safe-mode` and `--effort` support; tested with version **2.1.289**.

**Sign in:** run `claude` and use `/login`, or run `codex login`. Installers do not install the CLIs or sign you in. The Windows installer does not create scheduled tasks; Ubuntu setup creates the cron schedule described above.

## Usage

| Command | Default model | Request |
| --- | --- | --- |
| `claude-ping` | `haiku` | Short system prompt, safe mode, low effort; tools and MCP disabled |
| `codex-ping` | `gpt-5.6-luna` | Direct request with low reasoning effort; CLI fallback on HTTP 401 |

Pass a model name as the only argument:

```bat
claude-ping sonnet
codex-ping gpt-5.6-sol
```

Every run makes a **real model request and consumes account usage**. Model availability depends on your account. If a default model is unavailable, pass a supported name.

Claude disables thinking where the model supports it. These settings apply only to the ping process. Another ping does not move the reset time of an active usage window.

## Example output

Illustrative Claude output:

```text
[2026-10-05 10:00:00] OK: 'ok'
  login=claude-user@example.com
  model=haiku
  TOKENS
  input=20  output=3  total=83
  cache_write=10  cached=50

  LIMITS
  5-hour    [##------------------]  remaining=87.5%  used=12.5%
            resets=2026-10-05 12:00:00 +03:00
            in 0d 01:59:59

  weekly    [#######-------------]  remaining=65%  used=35%
            resets=2026-10-10 10:00:00 +03:00
            in 4d 23:59:59
```

| Field | Meaning |
| --- | --- |
| `login` | Current provider account email; `unavailable` if identity metadata is missing |
| `TOKENS` | Token counts for this ping, including cache statistics |
| `used` / `remaining` | Account quota percentages, not exact remaining token counts |
| `resets` | Server reset time in the machine's local time zone |
| `in` | Countdown in days and `HH:MM:SS` |
| `n/a` / `unknown` | The service did not return a value |

Claude adds uncached input, cache writes, cache reads, and output to get `total`. Codex includes cached tokens in input and reasoning tokens in output, so neither is added a second time. Quota statistics requests do not generate model responses.

**Exit codes:** `0` means success; `1` means failure. If the ping succeeds but quota statistics are unavailable, a warning is printed and the exit code remains `0`.

## Scheduling

Example: run Claude Ping daily at **07:00 local time** while signed in to Windows. Run in PowerShell:

```powershell
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c "%USERPROFILE%\.local\bin\claude-ping.bat"'
$trigger = New-ScheduledTaskTrigger -Daily -At '07:00'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
Register-ScheduledTask -TaskName 'claude-ping' -Action $action -Trigger $trigger -Settings $settings
```

Use `codex-ping` in the task name and script path for Codex. [The detailed Russian guide](ai-ping.md#запуск-по-расписанию) covers multiple triggers, logging, and task management.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| CLI or ping command not found | Verify installation and `PATH`; open a new terminal |
| Authentication failure | Sign in again: `claude` → `/login`, or `codex login` |
| Model unavailable | Pass a model supported by your account |
| Quota warning | Check the connection and subscription sign-in |
| Antivirus warning | Keep protection enabled; review the files and detection instead of adding exclusions |

The internet installers save files to disk before running local setup. Windows scripts use PowerShell; Ubuntu scripts use Bash and Python 3. Authentication files stay in your user profile; backups, credentials, and temporary test profiles are excluded from Git. On Ubuntu, Codex reads `CODEX_HOME/auth.json` (default `~/.codex/auth.json`); Claude reads `CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude/.credentials.json`). Codex's direct request requires file-based ChatGPT authentication.

## Development

There is no build step. Offline checks use mocked CLIs, HTTP responses, ZIP fixtures, and an isolated registry. They do not make model requests or use real credentials.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-claude-ping.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-codex-ping.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-install.ps1
```

Ubuntu checks use isolated homes, mocked crontab/CLI commands, local archives, and HTTP fixtures:

```bash
python3 test-ubuntu.py
bash test-ubuntu.sh
```

[Report a problem](https://github.com/dprytkov/ai-ping/issues) with the command, Windows/CLI versions, and sanitized output. Redact your login email before sharing logs.

## License

[MIT](LICENSE) · Copyright © 2026 [dprytkov](https://github.com/dprytkov).

---

<p align="center"><a href="README.ru.md">Русская версия</a> · <a href="ai-ping.md">Detailed Russian guide</a></p>
