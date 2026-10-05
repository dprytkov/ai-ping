#!/usr/bin/env bash
# Copyright (c) 2026 dprytkov. SPDX-License-Identifier: MIT
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
command -v python3 >/dev/null 2>&1 || { echo 'FAIL: python3 not found in PATH' >&2; exit 1; }
exec python3 "$script_directory/ai-ping.py" claude "$@"
