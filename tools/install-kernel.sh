#!/usr/bin/env bash
# Install a kernel built by tools/build-kernel.sh onto the Ultra 10 disk (made by prepare-disk.sh) as an EXTRA boot
# entry: vmlinux -> /boot, modules -> the rootfs, then regenerate /boot/grub/grub.cfg with every kernel found.
# The older kernels stay and remain selectable. GRUB itself (boot block, core.img) is NOT touched, so the disk keeps
# booting even if this fails half way (grub.cfg is a plain file read at boot).
#
# SAFE BY DEFAULT: without --go it only prints. With --go it needs root and --confirm <disk basename>.
#
# usage: install-kernel.sh --disk /dev/sdX [--kernel-dir DIR] [--default new|old|<release>] [--kargs "..."] [--go --confirm sdX]
#   --kernel-dir  output of build-kernel.sh (default: newest build/kernel/out/*)
#   --ab          write root-a and root-b entries (detected automatically from the existing grub.cfg)
#   --default     which kernel is entry 0 (default: new)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DISK= KDIR= GO=0 CONFIRM= DEFAULT=new KARGS="rootwait" AB=0
MNT=/mnt/sparc-target
while [ $# -gt 0 ]; do
	case $1 in
	--disk) DISK=$2; shift 2;;
	--kernel-dir) KDIR=$2; shift 2;;
	--default) DEFAULT=$2; shift 2;;
	--kargs) KARGS=$2; shift 2;;
	--ab) AB=1; shift;;
	--mnt) MNT=$2; shift 2;;
	--go) GO=1; shift;;
	--confirm) CONFIRM=$2; shift 2;;
	-h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0;;
	*) echo "unknown option: $1" >&2; exit 1;;
	esac
done
[ -n "$DISK" ] || { echo "need --disk" >&2; exit 1; }
[ -b "$DISK" ] || { echo "$DISK is not a block device" >&2; exit 1; }
[ -n "$KDIR" ] || KDIR=$(ls -dt "$ROOT"/build/kernel/out/*/ | head -1)
KDIR=${KDIR%/}
for f in vmlinux release config System.map; do [ -e "$KDIR/$f" ] || { echo "$KDIR/$f missing (run tools/build-kernel.sh)" >&2; exit 1; }; done
[ -d "$KDIR/modules" ] || { echo "$KDIR/modules missing" >&2; exit 1; }
REL=$(cat "$KDIR/release")

# ---- safety (same rules as prepare-disk.sh) -------------------------------------------------
name=$(basename "$DISK")
rootsrc=$(findmnt -no SOURCE / || true); rootdisk=$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -1 || true)
[ "$name" != "${rootdisk:-}" ] && [ "$DISK" != "$rootsrc" ] || { echo "REFUSING: $DISK holds the running root filesystem" >&2; exit 1; }
if lsblk -no MOUNTPOINTS "$DISK" | grep -q .; then echo "REFUSING: something on $DISK is mounted" >&2; lsblk -o NAME,MOUNTPOINTS "$DISK" >&2; exit 1; fi
echo "target disk: $DISK  $(lsblk -dno SIZE,MODEL,TRAN "$DISK" | tr -s ' ')"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DISK"
echo "installing kernel $REL from $KDIR ($(du -sh "$KDIR/modules" | cut -f1) of modules)"
if [ "$GO" = 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "--go needs root (sudo)" >&2; exit 1; }
	[ "$CONFIRM" = "$name" ] || { echo "--go also needs: --confirm $name" >&2; exit 1; }
else
	echo; echo "*** DRY RUN: nothing will be changed. Add: --go --confirm $name ***"
fi
run() { printf '+ %s\n' "$*"; if [ "$GO" = 1 ]; then "$@"; fi; }
pdev() { case $DISK in *[0-9]) echo "${DISK}p$1";; *) echo "${DISK}$1";; esac; }

cleanup() { set +e; mountpoint -q "$MNT/boot" && umount "$MNT/boot"; mountpoint -q "$MNT" && umount "$MNT"; return 0; }
trap cleanup EXIT
run mkdir -p "$MNT"
run mount "$(pdev 4)" "$MNT"
run mount "$(pdev 1)" "$MNT/boot"

# ---- files ----------------------------------------------------------------------------------
run cp "$KDIR/vmlinux" "$MNT/boot/vmlinux-$REL"
run cp "$KDIR/config" "$MNT/boot/config-$REL"
run cp "$KDIR/System.map" "$MNT/boot/System.map-$REL"
# modules go where /lib/modules points (merged-/usr rootfs: /lib -> usr/lib); root-owned
moddst=$MNT/usr/lib/modules
if [ "$GO" = 1 ] && [ ! -d "$moddst" ]; then moddst=$MNT/lib/modules; fi
run mkdir -p "$moddst"
run bash -c "tar -C '$KDIR/modules/lib/modules' --owner=0 --group=0 --numeric-owner -cf - '$REL' | tar -C '$moddst' --numeric-owner -xpf -"

run install -D -m 755 "$ROOT/tools/guest/bench.sh" "$MNT/root/bench.sh"

# ---- grub.cfg -------------------------------------------------------------------------------
case $DEFAULT in
	new) def=$REL;;
	old) def=;;            # keep whatever sorts first among the others: handled below
	*) def=$DEFAULT;;
esac
if [ "$GO" = 1 ]; then
	cfgargs=(--kargs "$KARGS")
	if [ "$DEFAULT" = old ]; then
		def=$(cd "$MNT/boot" && ls vmlinux-* | sed 's/^vmlinux-//' | grep -vx "$REL" | sort -rV | head -1)
	fi
	[ -z "$def" ] || cfgargs+=(--default "$def")
	# keep the A/B entries if the current grub.cfg has them (or --ab was given)
	[ "$AB" = 1 ] || ! grep -q 'rootfs-b' "$MNT/boot/grub/grub.cfg" || { AB=1; echo "A/B layout detected in grub.cfg: keeping the rootfs-b entries"; }
	[ "$AB" = 0 ] || cfgargs+=(--ab)
	cp "$MNT/boot/grub/grub.cfg" "$MNT/boot/grub/grub.cfg.bak"
	"$ROOT/tools/make-grub-cfg.sh" "$MNT/boot" "${cfgargs[@]}" >"$MNT/boot/grub/grub.cfg.new"
	mv "$MNT/boot/grub/grub.cfg.new" "$MNT/boot/grub/grub.cfg"
	echo; cat "$MNT/boot/grub/grub.cfg"; echo; ls -l "$MNT/boot"; df -h "$MNT" "$MNT/boot" | tail -2
else
	echo "+ regenerate $MNT/boot/grub/grub.cfg (previous kept as grub.cfg.bak) with tools/make-grub-cfg.sh, default=$DEFAULT"
fi
[ "$GO" = 1 ] && sync
echo; echo "done. Reboot the Ultra 10 and boot disk; the new kernel is $([ "$DEFAULT" = new ] && echo 'entry 0 (default)' || echo "selectable but not default")."
echo "If it fails: put the disk back on the PC and run this script with --default old, or boot the old entry (Ctrl-N in the GRUB menu may select it)."
