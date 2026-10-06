#!/usr/bin/env bash
# Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
# Ping both providers with their default models, even if one fails.
set -uo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
status=0
for provider in codex claude; do
    printf '=== %s ===\n' "$provider"
    script=$script_directory/$provider-ping
    if [[ ! -f $script ]]; then script+=.sh; fi
    bash "$script" || status=1
    printf '\n'
done
exit "$status"
