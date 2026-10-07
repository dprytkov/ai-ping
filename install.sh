#!/usr/bin/env bash
# Download an archive to disk, then invoke the local Linux installer.
# Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
set -euo pipefail
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found in PATH."
done
temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT
echo 'Downloading AI Ping archive...'
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --max-time 60 --output "$temporary_directory/ai-ping.tar.gz" \
    'https://github.com/dprytkov/ai-ping/archive/refs/heads/main.tar.gz' || fail 'Archive download failed.'
[[ -s $temporary_directory/ai-ping.tar.gz ]] || fail 'Archive download is missing or empty.'
tar -xzf "$temporary_directory/ai-ping.tar.gz" -C "$temporary_directory" || fail 'Archive extraction failed.'
setup=$temporary_directory/ai-ping-main/ai-ping-setup.sh
[[ -f $setup ]] || fail 'Archive does not contain ai-ping-setup.sh.'
# A curl | bash launch uses a pipe for stdin. Keep setup prompts on the terminal.
if [[ ! -t 0 && -t 1 ]] && { : </dev/tty; } 2>/dev/null; then
    bash "$setup" "$@" </dev/tty || fail 'Local installer failed.'
else
    bash "$setup" "$@" || fail 'Local installer failed.'
fi
