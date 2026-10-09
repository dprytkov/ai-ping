#!/bin/sh
# Canonical cron entrypoint: settings and profiles are owned by the root helper.
set -eu
umask 077
case "${1:-}" in
    --scheduled) exec /usr/bin/python3 /opt/ai-ping-web/runner.py scheduled >/dev/null 2>&1 ;;
    '') exec /usr/bin/python3 /opt/ai-ping-web/runner.py now ;;
    *) exit 2 ;;
esac
