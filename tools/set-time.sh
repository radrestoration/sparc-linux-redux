#!/usr/bin/env bash
# Set the Ultra 10's clock from this PC over ssh (its RTC battery is dead, so every boot starts with a wrong time).
# usage: tools/set-time.sh [user@host]      (default root@192.168.2.20)
set -euo pipefail
ssh "${1:-root@192.168.2.20}" "date -u -s @$(date -u +%s) >/dev/null && echo \"target clock now: \$(date -u)\""
