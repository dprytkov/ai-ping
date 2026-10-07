#!/usr/bin/env bash
# Offline setup, cron, wrapper and download tests. No real crontab or network.
set -euo pipefail
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d "$source_directory/.ubuntu-test-XXXXXX")
# The cleanup target must be this test's generated child of the workspace.
[[ $test_root = "$source_directory"/.ubuntu-test-* && -d $test_root ]] || exit 1
trap 'rm -rf -- "$test_root"' EXIT
export TMPDIR=$test_root/tmp
export HOME="$test_root/home with 'quotes' and %percent"
export TEST_CRONTAB=$test_root/crontab
export TEST_CALLS=$test_root/calls
export TEST_REAL_DATE
TEST_REAL_DATE=$(command -v date)
export TZ=UTC
export PATH="$test_root/bin:$PATH"
unset SUDO_USER CLAUDE_CONFIG_DIR CODEX_HOME
mkdir -p -- "$TMPDIR" "$HOME" "$test_root/bin" "$test_root/fixture/ai-ping-main"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "Missing expected text: $2"; }
assert_empty_temp() { [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]] || fail 'Temporary downloads were not cleaned.'; }
expect_failure() {
    if "$@" >"$test_root/output" 2>&1; then fail 'Expected failure'; fi
    assert_contains "$test_root/output" 'FAIL:'
    assert_empty_temp
}
for name in ai-ping-setup.sh install.sh claude-ping.sh codex-ping.sh ai-ping.sh; do
    bash -n "$source_directory/$name"
done
cp -- "$source_directory/ai-ping-setup.sh" "$source_directory/claude-ping.sh" \
    "$source_directory/codex-ping.sh" "$source_directory/ai-ping.sh" "$source_directory/ai-ping.py" "$source_directory/LICENSE" \
    "$test_root/fixture/ai-ping-main/"
cat >"$test_root/bin/crontab" <<'MOCK'
#!/usr/bin/env bash
if [[ ${TEST_CRON_ERROR:-} = read ]]; then echo 'permission denied' >&2; exit 1; fi
if [[ $1 = -l ]]; then
    if [[ -f $TEST_CRONTAB ]]; then cat "$TEST_CRONTAB"; else echo 'no crontab for offline-user' >&2; exit 1; fi
else
    [[ ${TEST_CRON_ERROR:-} != write ]] || exit 1
    cp -- "$1" "$TEST_CRONTAB"
fi
MOCK
cat >"$test_root/bin/python3" <<'MOCK'
#!/usr/bin/env bash
[[ ($# = 2 || $# = 3) && -f $1 && $1 = */ai-ping.py ]] || exit 91
if [[ $# = 2 ]]; then
    case "$2" in codex) set -- "$@" gpt-5.6-luna ;; claude) set -- "$@" haiku ;; *) exit 91 ;; esac
fi
if [[ $2 = --setup-auth ]]; then
    [[ $3 = both || $3 = claude || $3 = codex ]] || exit 91
    if [[ ${TEST_AUTH_FAILURE:-0} = 1 ]]; then echo 'FAIL: offline authorization failure' >&2; exit 1; fi
    exit 0
fi
printf '%s %s\n' "$2" "$3" >>"$TEST_CALLS"
echo "OK: offline $2 $3"
[[ ${TEST_PROVIDER_FAILURE:-} != "$2" ]]
MOCK
cat >"$test_root/bin/flock" <<'MOCK'
#!/usr/bin/env bash
[[ $* = '-n 9' ]] || exit 91
[[ ${TEST_LOCK_BUSY:-0} != 1 ]]
MOCK
cat >"$test_root/bin/date" <<'MOCK'
#!/usr/bin/env bash
[[ $* = '+%H:%M' && -n ${TEST_NOW_UTC:-} ]] || exit 91
exec "$TEST_REAL_DATE" --date "$TEST_NOW_UTC UTC" '+%H:%M'
MOCK
cat >"$test_root/bin/curl" <<'MOCK'
#!/usr/bin/env bash
[[ ${TEST_DOWNLOAD_SCENARIO:-} != failure ]] || exit 22
target=''
while (($#)); do
    case "$1" in --output) target=$2; shift 2 ;; *) shift ;; esac
done
[[ -n $target ]] || exit 92
case ${TEST_DOWNLOAD_SCENARIO:-success} in
    empty) : >"$target" ;;
    corrupt) echo invalid >"$target" ;;
    *) cp -- "$TEST_ARCHIVE" "$target" ;;
esac
MOCK
chmod +x "$test_root/bin/"*

# Start with an unrelated cron job and a shell profile that must survive setup.
echo '15 3 * * * echo unrelated' >"$TEST_CRONTAB"
echo '# existing shell settings' >"$HOME/.bashrc"
setup=$source_directory/ai-ping-setup.sh
bash "$setup" --provider both </dev/null >"$test_root/output"
assert_contains "$test_root/output" 'Daily schedule (Europe/Moscow): 06:00 11:01 16:02 21:03'
assert_contains "$TEST_CRONTAB" '# Daily (Europe/Moscow): 06:00 11:01 16:02 21:03'
assert_contains "$TEST_CRONTAB" '* * * * * /bin/bash '
assert_contains "$TEST_CRONTAB" ' --scheduled'
assert_contains "$HOME/.local/bin/ai-ping-run" 'export TZ=Europe/Moscow'
assert_contains "$TEST_CRONTAB" '15 3 * * * echo unrelated'
for name in claude-ping codex-ping ai-ping ai-ping.py ai-ping-run ai-ping-LICENSE.txt; do
    [[ -f $HOME/.local/bin/$name ]] || fail "Missing installed file: $name"
done
cmp "$source_directory/claude-ping.sh" "$HOME/.local/bin/claude-ping"
cmp "$source_directory/codex-ping.sh" "$HOME/.local/bin/codex-ping"
cmp "$source_directory/ai-ping.sh" "$HOME/.local/bin/ai-ping"
cmp "$source_directory/ai-ping.py" "$HOME/.local/bin/ai-ping.py"
cmp "$source_directory/LICENSE" "$HOME/.local/bin/ai-ping-LICENSE.txt"
[[ ! -e $TEST_CALLS ]] || fail 'Installer sent a ping'
assert_empty_temp
pass 'Install, preserved cron jobs, file copying, no ping during setup'

# Manual combined command uses defaults and attempts both providers on failure.
for failure in none codex claude; do
    : >"$TEST_CALLS"
    status=0
    TEST_PROVIDER_FAILURE=$failure bash "$HOME/.local/bin/ai-ping" >"$test_root/output" || status=$?
    expected=1
    if [[ $failure = none ]]; then expected=0; fi
    [[ $status = "$expected" ]] || fail 'Unexpected combined ping exit code'
    [[ $(cat "$TEST_CALLS") = $'codex gpt-5.6-luna\nclaude haiku' ]] || fail 'Combined ping skipped a provider or changed defaults'
done
: >"$TEST_CALLS"
bash "$source_directory/ai-ping.sh" >"$test_root/output"
[[ $(cat "$TEST_CALLS") = $'codex gpt-5.6-luna\nclaude haiku' ]] || fail 'Source combined command failed'
rm -- "$TEST_CALLS"
pass 'Combined command from source and installation, defaults, both attempts and exit codes'

# Cron's/server's UTC clock must still trigger exactly the Windows Moscow slots.
for utc_time in 03:00 08:01 13:02 18:03; do
    calls_before=0
    if [[ -f $TEST_CALLS ]]; then calls_before=$(wc -l <"$TEST_CALLS"); fi
    TEST_NOW_UTC="2026-10-06 $utc_time:00" bash "$HOME/.local/bin/ai-ping-run" --scheduled
    [[ $(wc -l <"$TEST_CALLS") = $((calls_before + 2)) ]] || fail "Windows slot was skipped: $utc_time UTC"
done
calls_before=$(wc -l <"$TEST_CALLS")
for utc_time in 02:59 03:01 08:00 08:02 13:01 13:03 18:02 18:04 06:00 11:01 16:02 21:03; do
    TEST_NOW_UTC="2026-10-06 $utc_time:00" bash "$HOME/.local/bin/ai-ping-run" --scheduled
done
[[ $(wc -l <"$TEST_CALLS") = "$calls_before" ]] || fail 'Runner pinged outside the Windows-time schedule'
pass 'Four Windows Moscow slots on a UTC server, no pings on other minute ticks'

bash "$setup" --start 07:30 --provider codex --codex-model gpt-5.6-sol >"$test_root/output"
assert_contains "$test_root/output" '07:30 12:31 17:32 22:33'
[[ $(grep -c '^# BEGIN AI-PING$' "$TEST_CRONTAB") = 1 ]] || fail 'Duplicate cron block'
[[ $(grep -c '^# BEGIN AI-PING PATH$' "$HOME/.bashrc") = 1 ]] || fail 'Duplicate Bash PATH block'
[[ $(grep -c '^# BEGIN AI-PING PATH$' "$HOME/.profile") = 1 ]] || fail 'Duplicate profile PATH block'
assert_contains "$HOME/.bashrc" '# existing shell settings'
profile_path=$(HOME="$HOME" bash --noprofile --norc -c 'source "$HOME/.profile"; source "$HOME/.bashrc"; source "$HOME/.profile"; printf "%s" "$PATH"')
[[ $profile_path != "$HOME/.local/bin:$HOME/.local/bin:"* ]] || fail 'Profiles duplicated the installation PATH'
[[ $(grep -c '^\* \* \* \* \* /bin/bash ' "$TEST_CRONTAB") = 1 ]] || fail 'Duplicate scheduled tick'
assert_contains "$HOME/.local/bin/ai-ping-run" '07:30|12:31|17:32|22:33'
# Simulate cron's removal of escaped percent signs, then execute its shell command.
cron_line=$(grep '^\* \* \* \* \* /bin/bash ' "$TEST_CRONTAB")
cron_command=$(printf '%s\n' "$cron_line" | cut -d ' ' -f 6-)
cron_command=${cron_command//\\%/%}
TEST_NOW_UTC='2026-10-06 04:30:00' /bin/sh -c "$cron_command"
assert_contains "$TEST_CALLS" 'codex gpt-5.6-sol'
assert_contains "$HOME/.local/state/ai-ping/ai-ping.log" 'OK: offline codex gpt-5.6-sol'
pass 'Repeated install, five hours plus one minute, cron quoting with spaces/quotes/percent'

# Other Windows zones can be selected without changing the machine or other jobs.
bash "$setup" --start 06:00 --provider codex --timezone Asia/Kolkata >"$test_root/output"
assert_contains "$test_root/output" 'Daily schedule (Asia/Kolkata): 06:00 11:01 16:02 21:03'
calls_before=$(wc -l <"$TEST_CALLS")
TEST_NOW_UTC='2026-10-06 00:30:00' bash "$HOME/.local/bin/ai-ping-run" --scheduled
[[ $(wc -l <"$TEST_CALLS") = $((calls_before + 1)) ]] || fail 'Half-hour time zone did not fire'
assert_contains "$TEST_CRONTAB" '15 3 * * * echo unrelated'
bash "$setup" --start 06:00 --provider codex --timezone Europe/Berlin >"$test_root/output"
calls_before=$(wc -l <"$TEST_CALLS")
TEST_NOW_UTC='2026-07-06 04:00:00' bash "$HOME/.local/bin/ai-ping-run" --scheduled
TEST_NOW_UTC='2026-01-06 05:00:00' bash "$HOME/.local/bin/ai-ping-run" --scheduled
[[ $(wc -l <"$TEST_CALLS") = $((calls_before + 2)) ]] || fail 'Time zone did not track summer/winter offset'
pass 'Configurable Windows time zone, half-hour offset and summer/winter time'

# Auth collection must succeed before cron, installed commands or profiles change.
saved_cron=$(cat "$TEST_CRONTAB")
saved_runner=$(cat "$HOME/.local/bin/ai-ping-run")
saved_profile=$(cat "$HOME/.profile")
TEST_AUTH_FAILURE=1 expect_failure bash "$setup" --start 09:00 --provider both
[[ $(cat "$TEST_CRONTAB") = "$saved_cron" ]] || fail 'Authorization failure changed cron'
[[ $(cat "$HOME/.local/bin/ai-ping-run") = "$saved_runner" ]] || fail 'Authorization failure changed runner'
[[ $(cat "$HOME/.profile") = "$saved_profile" ]] || fail 'Authorization failure changed profile'
pass 'Authorization failure preserves schedule, runner and profile'

# CLI paths and alternate profile directories survive a minimal cron environment.
export CLAUDE_CONFIG_DIR="$HOME/custom claude"
export CODEX_HOME="$HOME/custom codex"
bash "$setup" --start 08:00 --provider both --claude-model sonnet >"$test_root/output"
assert_contains "$HOME/.local/bin/ai-ping-run" 'export CLAUDE_CONFIG_DIR='
assert_contains "$HOME/.local/bin/ai-ping-run" 'export CODEX_HOME='
export TEST_PROVIDER_FAILURE=claude
if bash "$HOME/.local/bin/ai-ping-run"; then fail 'Runner ignored provider failure'; fi
assert_contains "$TEST_CALLS" 'claude sonnet'
assert_contains "$TEST_CALLS" 'codex gpt-5.6-luna'
unset TEST_PROVIDER_FAILURE
calls_before=$(wc -l <"$TEST_CALLS")
TEST_LOCK_BUSY=1 bash "$HOME/.local/bin/ai-ping-run"
[[ $(wc -l <"$TEST_CALLS") = "$calls_before" ]] || fail 'Busy lock did not skip the run'
pass 'Runner attempts both providers, returns failure, skips overlapping runs'

bash "$setup" --start 23:00 --provider claude >"$test_root/output"
assert_contains "$TEST_CRONTAB" '# Daily (Europe/Moscow): 23:00'
assert_contains "$HOME/.local/bin/ai-ping-run" '        23:00) ;;'
saved_cron=$(cat "$TEST_CRONTAB")
for time in 23:01 24:00 7:30 08:60 nonsense; do expect_failure bash "$setup" --start "$time"; done
expect_failure bash "$setup" --provider invalid
expect_failure bash "$setup" --claude-model 'bad model'
expect_failure bash "$setup" --codex-model '--unsafe'
expect_failure bash "$setup" --start
expect_failure bash "$setup" --unknown
expect_failure bash "$setup" --timezone
for zone in missing/zone ../etc/passwd /etc/passwd 'Europe/Moscow bad' ''; do
    expect_failure bash "$setup" --timezone "$zone"
done
[[ $(cat "$TEST_CRONTAB") = "$saved_cron" ]] || fail 'Invalid input changed the crontab'
pass '23:00 boundary, invalid options leave cron untouched'

export TEST_CRON_ERROR=read
expect_failure bash "$setup" --start 08:00
[[ $(cat "$TEST_CRONTAB") = "$saved_cron" ]] || fail 'Read error changed the crontab'
export TEST_CRON_ERROR=write
expect_failure bash "$setup" --start 08:00
unset TEST_CRON_ERROR
export SUDO_USER=offline-user
expect_failure bash "$setup" --start 08:00
unset SUDO_USER
echo '# BEGIN AI-PING' >>"$TEST_CRONTAB"
expect_failure bash "$setup" --start 08:00
printf '%s\n' "$saved_cron" >"$TEST_CRONTAB"
pass 'Read/write errors, sudo and damaged cron blocks fail safely'

rm -- "$TEST_CRONTAB"
bash "$setup" --start 09:00 --provider claude >"$test_root/output"
assert_contains "$test_root/output" '09:00 14:01 19:02'
pass 'First installation with no existing user crontab'

bash "$setup" </dev/null >"$test_root/output"
assert_contains "$test_root/output" '06:00 11:01 16:02 21:03'
assert_contains "$test_root/output" 'Provider: both'
bash "$setup" --start 00:00 --provider claude --claude-model 'sonnet[1m]' >"$test_root/output"
assert_contains "$test_root/output" '00:00 05:01 10:02 15:03 20:04'
pass 'Noninteractive defaults, midnight and bracketed model names'

export TEST_ARCHIVE=$test_root/archive.tar.gz
tar -czf "$TEST_ARCHIVE" -C "$test_root/fixture" ai-ping-main
bash "$source_directory/install.sh" --start 08:00 --provider codex >"$test_root/output"
assert_contains "$test_root/output" '08:00 13:01 18:02'
assert_empty_temp
for scenario in failure empty corrupt; do
    export TEST_DOWNLOAD_SCENARIO=$scenario
    expect_failure bash "$source_directory/install.sh" --start 08:00
done
unset TEST_DOWNLOAD_SCENARIO
expect_failure bash "$source_directory/install.sh" --start invalid
mkdir -p "$test_root/partial/ai-ping-main"
tar -czf "$test_root/partial.tar.gz" -C "$test_root/partial" ai-ping-main
export TEST_ARCHIVE=$test_root/partial.tar.gz
expect_failure bash "$source_directory/install.sh" --start 08:00
pass 'Download/install path, local archives, download/empty/corrupt/missing-setup failures and cleanup'
echo 'All Linux shell checks passed; no network requests or real cron changes were made.'
