#!/usr/bin/env bash
# Install a kernel built by tools/build-kernel.sh onto the RUNNING Ultra 10 over ssh (no disk shuffling):
# vmlinux/config/System.map -> /boot, modules -> /usr/lib/modules, then regenerate /boot/grub/grub.cfg from the kernels
# found there (tools/make-grub-cfg.sh). GRUB itself (boot block, core.img) is never touched, so a bad kernel can be
# undone by editing grub.cfg ('set default=') from the PC, or from the GRUB menu.
#
# One ssh connection is shared (ControlMaster), so a password is asked once.
# SAFE BY DEFAULT: without --go it only prints what it would do (it does still ask the target a few read-only questions).
#
# usage: push-kernel.sh --host root@192.168.2.20 [--kernel-dir DIR] [--default new|REL] [--kargs "..."] [--no-modules] [--dma-tests] [--ab] [--go] [--reboot]
#   --no-modules  skip the modules (use when only a built-in driver changed and the release string is the same)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST= KDIR= DEFAULT=new KARGS="rootwait" GO=0 REBOOT=0 NOMOD=0 DMATESTS=0 AB=0
while [ $# -gt 0 ]; do
	case $1 in
	--host) HOST=$2; shift 2;;
	--kernel-dir) KDIR=$2; shift 2;;
	--default) DEFAULT=$2; shift 2;;
	--kargs) KARGS=$2; shift 2;;
	--go) GO=1; shift;;
	--reboot) REBOOT=1; shift;;
	--no-modules) NOMOD=1; shift;;
	--dma-tests) DMATESTS=1; shift;;
	--ab) AB=1; shift;;
	-h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0;;
	*) echo "unknown option: $1" >&2; exit 1;;
	esac
done
[ -n "$HOST" ] || { echo "need --host root@ADDRESS" >&2; exit 1; }
[ -n "$KDIR" ] || KDIR=$(ls -dt "$ROOT"/build/kernel/out/*/ | head -1)
KDIR=${KDIR%/}
for f in vmlinux release config System.map; do [ -e "$KDIR/$f" ] || { echo "$KDIR/$f missing (run tools/build-kernel.sh)" >&2; exit 1; }; done
[ -d "$KDIR/modules/lib/modules" ] || { echo "$KDIR/modules/lib/modules missing" >&2; exit 1; }
REL=$(cat "$KDIR/release")

SOCK=$(mktemp -u /tmp/push-kernel.XXXXXX)
SSH=(ssh -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=120 -o StrictHostKeyChecking=accept-new "$HOST")
trap 'ssh -o ControlPath="$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT
r() { "${SSH[@]}" "$@"; }                       # run on the target
run() { printf '+ %s\n' "$*"; if [ "$GO" = 1 ]; then "$@"; fi; }

echo "target: $HOST   installing kernel $REL from $KDIR"
echo "== target state (read-only)"
r 'uname -srm; mountpoint -q /boot && echo "/boot mounted" || echo "/boot NOT mounted"; df -h /boot / | tail -2; ls /boot | tr "\n" " "; echo'
[ "$GO" = 1 ] || echo "*** DRY RUN: nothing will be changed. Add --go ***"

r 'mountpoint -q /boot || mount /boot' >/dev/null 2>&1 || { echo "cannot mount /boot on the target" >&2; exit 1; }

# files: copy under a temporary name, then rename, so an interrupted copy never leaves a half-written vmlinux
for f in vmlinux:vmlinux-$REL config:config-$REL System.map:System.map-$REL; do
	src=${f%%:*}; dst=${f#*:}
	run scp -o ControlPath="$SOCK" "$KDIR/$src" "$HOST:/boot/$dst.new"
	run "${SSH[@]}" "mv /boot/$dst.new /boot/$dst"
done
if [ "$NOMOD" = 1 ]; then echo "+ modules skipped (--no-modules)"; else echo "+ modules: tar | ssh tar  ->  /usr/lib/modules/$REL"; fi
if [ "$GO" = 1 ] && [ "$NOMOD" = 0 ]; then
	tar -C "$KDIR/modules/lib/modules" --owner=0 --group=0 --numeric-owner -cf - "$REL" | "${SSH[@]}" "mkdir -p /usr/lib/modules && tar -C /usr/lib/modules --numeric-owner -xpf -"
fi

# grub.cfg: list the kernels now on the target (plus the one just pushed), generate locally against placeholders
tmp=$(mktemp -d)
for n in $(r 'ls /boot' ); do case $n in vmlinux-*|initrd.img-*) : >"$tmp/$n";; esac; done
: >"$tmp/vmlinux-$REL"
def=; [ "$DEFAULT" = new ] && def=$REL || def=$DEFAULT
dt=(); [ "$DMATESTS" = 0 ] || dt=(--dma-tests)
# keep the A/B entries if the target's grub.cfg has them (or --ab was given)
if [ "$AB" = 1 ] || r 'grep -q rootfs-b /boot/grub/grub.cfg' 2>/dev/null; then dt+=(--ab); echo "A/B layout: keeping the rootfs-b entries"; fi
"$ROOT/tools/make-grub-cfg.sh" "$tmp" --kargs "$KARGS" --default "$def" "${dt[@]}" >"$tmp/grub.cfg"
echo "== new grub.cfg"; cat "$tmp/grub.cfg"
run "${SSH[@]}" "cp /boot/grub/grub.cfg /boot/grub/grub.cfg.bak"
run scp -o ControlPath="$SOCK" "$tmp/grub.cfg" "$HOST:/boot/grub/grub.cfg.new"
run "${SSH[@]}" "mv /boot/grub/grub.cfg.new /boot/grub/grub.cfg && sync"

if [ "$REBOOT" = 1 ]; then run "${SSH[@]}" reboot || true
else echo; echo "done. Reboot the Ultra 10 when ready:  ssh $HOST reboot"; fi
