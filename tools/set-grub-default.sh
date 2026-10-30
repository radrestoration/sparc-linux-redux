#!/usr/bin/env bash
# Choose GRUB's default entry on the RUNNING Ultra 10 by (part of) its title, over ssh: no arrow keys needed.
# usage: tools/set-grub-default.sh --host root@192.168.2.20 "text in the title" [--reboot | --poweroff]
# Lists the entries first; refuses if the text matches no entry or more than one.
set -euo pipefail
HOST= PAT= ACTION=
while [ $# -gt 0 ]; do
	case $1 in
	--host) HOST=$2; shift 2;;
	--reboot) ACTION=reboot; shift;;
	--poweroff) ACTION=poweroff; shift;;
	-h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0;;
	*) PAT=$1; shift;;
	esac
done
[ -n "$HOST" ] && [ -n "$PAT" ] || { echo "usage: $0 --host root@IP \"title text\" [--reboot|--poweroff]" >&2; exit 1; }
SOCK=$(mktemp -u /tmp/sgd.XXXXXX)
S=(ssh -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=60 "$HOST")
trap 'ssh -o ControlPath="$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT
cfg=$("${S[@]}" cat /boot/grub/grub.cfg)
echo "entries on the target:"; awk '/^menuentry /{printf "  %d  %s\n", n++, $0}' <<<"$cfg" | sed 's/ {$//; s/menuentry //'
hits=$(awk -v p="$PAT" '/^menuentry /{ if (index($0,p)) print n; n++ }' <<<"$cfg")
[ -n "$hits" ] || { echo "no entry contains: $PAT" >&2; exit 1; }
[ "$(wc -l <<<"$hits")" = 1 ] || { echo "more than one entry contains '$PAT': $(echo $hits); be more specific" >&2; exit 1; }
"${S[@]}" "cp -n /boot/grub/grub.cfg /boot/grub/grub.cfg.before-default && sed -i 's/^set default=.*/set default=$hits/' /boot/grub/grub.cfg && grep -m1 '^set default' /boot/grub/grub.cfg"
echo "default is now entry $hits"
[ -z "$ACTION" ] || { echo "running: $ACTION"; "${S[@]}" "$ACTION" || true; }
