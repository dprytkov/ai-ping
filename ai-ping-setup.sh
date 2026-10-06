#!/usr/bin/env bash
# Install for the current Ubuntu user and replace only the AI Ping cron block.
# Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
set -euo pipefail
umask 077

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
    echo 'Usage: bash ai-ping-setup.sh [--start HH:MM] [--provider both|claude|codex]'
    echo '       [--claude-model MODEL] [--codex-model MODEL]'
    echo '       [--timezone IANA_ZONE]'
    echo 'Defaults: 06:00, 11:01, 16:02, 21:03 in Europe/Moscow (Windows Moscow time).'
    echo 'Daily: first run + every 5 hours 1 minute, with no start later than 23:00.'
}
start=''
provider=''
claude_model=haiku
codex_model=gpt-5.6-luna
schedule_timezone=Europe/Moscow
while (($#)); do
    case "$1" in
        --start|--provider|--claude-model|--codex-model|--timezone)
            (($# >= 2)) || fail "Missing value for $1"
            case "$1" in
                --start) start=$2 ;;
                --provider) provider=$2 ;;
                --claude-model) claude_model=$2 ;;
                --codex-model) codex_model=$2 ;;
                --timezone) schedule_timezone=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -n ${HOME:-} && $HOME = /* ]] || fail 'HOME must be an absolute path.'
[[ $HOME != *$'\n'* && $HOME != *$'\r'* ]] || fail 'HOME contains a line break.'
# sudo would schedule against the wrong account and credentials.
[[ -z ${SUDO_USER:-} ]] || fail 'Run the installer as your normal user without sudo.'
for tool in python3 crontab flock install date; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found. Install dependencies: sudo apt install python3 cron util-linux"
done
if [[ -z $start ]]; then
    if [[ -t 0 ]]; then
        read -r -p "First daily run in $schedule_timezone (HH:MM) [06:00]: " start || fail 'Cannot read start time.'
    fi
    start=${start:-06:00}
fi
if [[ -z $provider ]]; then
    if [[ -t 0 ]]; then
        read -r -p 'Provider (both/claude/codex) [both]: ' provider || fail 'Cannot read provider.'
    fi
    provider=${provider:-both}
fi
[[ $start =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail 'Time must be HH:MM, from 00:00 to 23:00.'
first_minute=$((10#${start:0:2} * 60 + 10#${start:3:2}))
((first_minute <= 23 * 60)) || fail 'First run must not be later than 23:00.'
[[ $provider = both || $provider = claude || $provider = codex ]] || fail 'Provider must be both, claude or codex.'
[[ $schedule_timezone =~ ^[a-zA-Z0-9_+-]+(/[a-zA-Z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$schedule_timezone ]] || fail 'Invalid or unavailable IANA time zone; install tzdata and use a name such as Europe/Moscow.'
for model in "$claude_model" "$codex_model"; do
    model_pattern='^[a-zA-Z0-9][][a-zA-Z0-9._:/-]*$'
    [[ $model =~ $model_pattern ]] || fail 'Invalid model name.'
done

times=()
for ((minute=first_minute; minute<=23*60; minute+=5*60+1)); do
    printf -v time '%02d:%02d' "$((minute / 60))" "$((minute % 60))"
    times+=("$time")
done

source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for name in claude-ping.sh codex-ping.sh ai-ping.py LICENSE; do
    [[ -f $source_directory/$name ]] || fail "Missing source file: $name"
done
temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT
# Distinguish an empty user crontab from read/permission errors.
if ! LC_ALL=C crontab -l >"$temporary_directory/old-crontab" 2>"$temporary_directory/cron-error"; then
    if ! grep -q '^no crontab for ' "$temporary_directory/cron-error"; then
        fail 'Cannot read user crontab; existing jobs were not changed.'
    fi
fi
awk '
    $0 == "# BEGIN AI-PING" { inside = 1; next }
    $0 == "# END AI-PING" { inside = 0; next }
    !inside { print }
    END { if (inside) exit 1 }
' "$temporary_directory/old-crontab" >"$temporary_directory/new-crontab" || fail 'Unclosed AI-PING block in crontab; repair it with crontab -e.'

# Collect missing-CLI authorization before installing files or changing cron.
# Credentials are read privately by Python, never passed as shell arguments.
python3 "$source_directory/ai-ping.py" --setup-auth "$provider" || fail 'Authorization setup failed; schedule was not changed.'

target_directory=$HOME/.local/bin
state_directory=$HOME/.local/state/ai-ping
mkdir -p -- "$target_directory" "$state_directory"
install -m 755 -- "$source_directory/claude-ping.sh" "$target_directory/claude-ping"
install -m 755 -- "$source_directory/codex-ping.sh" "$target_directory/codex-ping"
install -m 644 -- "$source_directory/ai-ping.py" "$target_directory/ai-ping.py"
install -m 644 -- "$source_directory/LICENSE" "$target_directory/ai-ping-LICENSE.txt"

# Store paths and models, never credentials. Cron does not load shell profiles.
runner=$target_directory/ai-ping-run
{
    printf '#!/usr/bin/env bash\nset -uo pipefail\numask 077\n'
    printf 'export PATH=%q\n' "$target_directory:$PATH"
    printf 'export HOME=%q\n' "$HOME"
    printf 'export TZ=%q\n' "$schedule_timezone"
    # Ubuntu cron schedules in the daemon's zone. A minute tick plus this
    # local check keeps Windows wall-clock times even on a UTC Linux server.
    printf 'if [[ ${1:-} = --scheduled ]]; then\n'
    printf '    current_time=$(date +%%H:%%M) || exit 1\n'
    printf '    case "$current_time" in\n        %s) ;;\n        *) exit 0 ;;\n    esac\nfi\n' "$(IFS='|'; echo "${times[*]}")"
    for variable in CLAUDE_CONFIG_DIR CODEX_HOME; do
        if [[ -n ${!variable:-} ]]; then
            printf 'export %s=%q\n' "$variable" "${!variable}"
        fi
    done
    printf 'exec 9>%q\nflock -n 9 || exit 0\n' "$state_directory/run.lock"
    printf 'exec >>%q 2>&1\nstatus=0\n' "$state_directory/ai-ping.log"
    if [[ $provider = both || $provider = claude ]]; then
        printf '%q %q || status=1\n' "$target_directory/claude-ping" "$claude_model"
    fi
    if [[ $provider = both || $provider = codex ]]; then
        printf '%q %q || status=1\n' "$target_directory/codex-ping" "$codex_model"
    fi
    printf 'exit "$status"\n'
} >"$runner"
chmod 700 -- "$runner"

# Use POSIX shell quoting for cron; percent must be escaped even in quotes.
cron_command="/bin/bash '${runner//\'/\'\\\'\'}' --scheduled"
cron_command=${cron_command//%/\\%}
printf '# BEGIN AI-PING\n# Daily (%s): %s\n' "$schedule_timezone" "${times[*]}" >>"$temporary_directory/new-crontab"
printf '* * * * * %s\n' "$cron_command" >>"$temporary_directory/new-crontab"
printf '# END AI-PING\n' >>"$temporary_directory/new-crontab"
crontab "$temporary_directory/new-crontab" || fail 'Cannot install user crontab.'

# Ubuntu's .profile usually adds this directory; also cover non-login Bash.
for profile in "$HOME/.profile" "$HOME/.bashrc"; do
    if ! grep -q '^# BEGIN AI-PING PATH$' "$profile" 2>/dev/null; then
        # A login Bash reads .profile; Ubuntu's existing .profile may already
        # prepend .local/bin after sourcing .bashrc. Avoid prepending it twice.
        printf '\n# BEGIN AI-PING PATH\n' >>"$profile"
        if [[ $profile = "$HOME/.bashrc" ]]; then
            printf 'if ! shopt -q login_shell; then\n' >>"$profile"
        fi
        cat >>"$profile" <<'PROFILE'
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
PROFILE
        if [[ $profile = "$HOME/.bashrc" ]]; then
            printf 'fi\n' >>"$profile"
        fi
        printf '# END AI-PING PATH\n' >>"$profile"
    fi
done

printf 'OK: installed in %s\n' "$target_directory"
printf 'Daily schedule (%s): %s\n' "$schedule_timezone" "${times[*]}"
printf 'Provider: %s\nLog: %s/ai-ping.log\n' "$provider" "$state_directory"
printf 'Check the cron service: systemctl is-active cron\n'
printf 'Open a new Bash terminal, or run: export PATH="$HOME/.local/bin:$PATH"\n'
printf 'With installed CLIs, sign in beforehand: claude then /login; codex login.\n'
printf 'Installation sends no model requests. Re-run to update scripts or schedule.\n'
