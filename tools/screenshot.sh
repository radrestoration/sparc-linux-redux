#!/usr/bin/env bash
# Take a screenshot of the Ultra 10's framebuffer (X/CDE included) and save it as a PNG on this PC.
#
#   tools/screenshot.sh [root@192.168.2.20] [output.png]
#
# Logs in over ssh, runs fbcat /dev/fb0 there (the image build installs fbcat), streams the PPM straight back (nothing is left on the
# Ultra), then converts it locally with tools/fbshot-to-png.py, which corrects fbcat's wrong byte order for the 16-bit pixels.
# Default output: screenshots/shot-YYYYmmdd-HHMMSS.png
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${1:-root@192.168.2.20}
OUT=${2:-$ROOT/screenshots/shot-$(date +%Y%m%d-%H%M%S).png}
PPM=$(mktemp "${TMPDIR:-/tmp}/ultra10-shot.XXXXXX")
trap 'rm -f "$PPM"' EXIT

mkdir -p "$(dirname "$OUT")"
ssh "$HOST" 'fbcat /dev/fb0' >"$PPM"
[ -s "$PPM" ] || { echo "ERROR: no data from $HOST (is fbcat installed, and are you root or in the video group?)" >&2; exit 1; }
python3 -I "$ROOT/tools/fbshot-to-png.py" "$PPM" "$OUT" >/dev/null
echo "$OUT"
