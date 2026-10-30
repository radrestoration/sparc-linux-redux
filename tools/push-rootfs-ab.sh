#!/usr/bin/env bash
# Install a new rootfs onto the INACTIVE A/B root partition of the RUNNING Ultra 10 over ssh. The running root is never
# touched: the tar is streamed straight into the other partition (no copy in the 128 MB RAM / tmpfs).
# Afterwards the new root gets the identity it needs to be reachable: fstab label, ssh host keys, root's authorized_keys,
# hostname, network config, and the modules of the running kernel (when the tar lacks them).
# The target clock is set from this PC first (the Ultra 10 has a dead RTC battery; same as tools/set-time.sh).
# Finally GRUB's default is switched to the newest normal entry of the new root (needs the --ab entries; see push-kernel.sh --ab).
# The old grub.cfg is kept once as grub.cfg.before-rootfs-push.
#
# SAFE BY DEFAULT: without --go it only asks the target read-only questions and prints the plan.
#
# usage: push-rootfs-ab.sh --host root@192.168.2.20 [--rootfs-tar FILE] [--no-mkfs] [--keep ITEM,...] [--go]
#   --no-mkfs   do not reformat the inactive partition first (default: mkfs.ext4 so no stale files survive)
#   --keep      /etc items copied from the running root (default: ssh/ssh_host_*,network/interfaces,hostname,hosts,resolv.conf)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST= ROOTFS= GO=0 MKFS=1 KEEP="ssh/ssh_host_*,network/interfaces,hostname,hosts,resolv.conf"
while [ $# -gt 0 ]; do
	case $1 in
	--host) HOST=$2; shift 2;;
	--rootfs-tar) ROOTFS=$2; shift 2;;
	--no-mkfs) MKFS=0; shift;;
	--keep) KEEP=$2; shift 2;;
	--go) GO=1; shift;;
	-h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0;;
	*) echo "unknown option: $1" >&2; exit 1;;
	esac
done
[ -n "$HOST" ] || { echo "need --host root@ADDRESS" >&2; exit 1; }
[ -n "$ROOTFS" ] || ROOTFS=$ROOT/build/debian/rootfs.tar
[ -f "$ROOTFS" ] || { echo "rootfs not found: $ROOTFS" >&2; exit 1; }

SOCK=$(mktemp -u /tmp/push-rootfs-ab.XXXXXX)
SSH=(ssh -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=300 -o StrictHostKeyChecking=accept-new "$HOST")
trap 'ssh -o ControlPath="$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT
r() { "${SSH[@]}" "$@"; }

echo "== target state (read-only)"
# which root is running, and the other one
cur=$(r 'findmnt -no LABEL / 2>/dev/null || true')
[ -n "$cur" ] || cur=$(r 'dev=$(findmnt -no SOURCE /); blkid -o value -s LABEL "$dev"')
case $cur in
	rootfs-a) other=rootfs-b;;
	rootfs-b) other=rootfs-a;;
	*) echo "running root has label '$cur', expected rootfs-a or rootfs-b; refusing" >&2; exit 1;;
esac
dev=$(r "blkid -L $other") || { echo "no partition labelled $other on the target" >&2; exit 1; }
rel=$(r 'uname -r')
echo "running: $cur   inactive: $other ($dev)   kernel: $rel"
r "lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS $dev; df -h / | tail -1"
r "grep -q '^$dev ' /proc/mounts" && { echo "REFUSING: $dev is mounted on the target" >&2; exit 1; }
r "[ \"\$(blkid -o value -s LABEL \$(findmnt -no SOURCE /))\" != $other ]" || { echo "REFUSING: $other is the running root" >&2; exit 1; }
echo "rootfs: $ROOTFS ($(du -h "$ROOTFS" | cut -f1)); partition size above"

echo "== plan"
[ "$MKFS" = 0 ] || echo "  mkfs.ext4 -L $other $dev      (ERASES $other)"
echo "  set the target clock from this PC (its RTC battery is dead)"
echo "  mount $dev /mnt/$other; stream the tar into it"
echo "  /etc/fstab: copy of the running root's (boot, swap) with LABEL=$other for /"
echo "  copy from $cur: $KEEP, /root/.ssh/authorized_keys"
echo "  ensure /usr/lib/modules/$rel exists on $other"
echo "  set the GRUB default to the newest (root=$other) entry"
if [ "$GO" = 0 ]; then echo; echo "*** DRY RUN: nothing changed. Add --go ***"; exit 0; fi

# first, so the new files get sane timestamps
r "date -u -s @$(date -u +%s) >/dev/null && echo \"target clock now: \$(date -u)\""

MNT=/mnt/$other
r "mkdir -p $MNT"
[ "$MKFS" = 0 ] || r "mkfs.ext4 -q -F -L $other $dev"
r "mount $dev $MNT"
cleanup() { r "umount $MNT" >/dev/null 2>&1 || true; }
trap 'cleanup; ssh -o ControlPath="$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true' EXIT

echo "== unpacking (no output until done; ~390 MB over ssh)"
r "tar -C $MNT -xpf - --numeric-owner --xattrs --xattrs-include='*.*' --acls" <"$ROOTFS"

echo "== verifying the unpack on $dev"
want=$(tar -tf "$ROOTFS" | wc -l)
got=$(r "find $MNT -xdev -mindepth 1 | wc -l")
echo "  entries in tar: $want   on $other: $got"
r "grep -c '^Package: ' $MNT/var/lib/dpkg/status | sed 's/^/  packages in $other dpkg status: /'; ls -l $MNT/usr/bin/xterm $MNT/usr/bin/xclock 2>&1 | sed 's/^/  /'; df -h $MNT | tail -1"
[ "$got" -ge "$((want - 1))" ] || { echo "FAILED: $other has fewer files than the tar; not touching GRUB" >&2; exit 1; }

echo "== fixing identity"
r "set -e
# the tar carries no fstab (prepare-disk.sh owns it): reuse the running root's, switching only the root label
cp -a /etc/fstab $MNT/etc/fstab
sed -i -E 's|^[^#[:space:]]+([[:space:]]+/[[:space:]])|LABEL=$other\1|' $MNT/etc/fstab
grep -E '^[^#].*[[:space:]]/[[:space:]]' $MNT/etc/fstab
IFS=,; for k in $KEEP; do
	for f in /etc/\$k; do [ -e \"\$f\" ] || continue; mkdir -p \"$MNT\$(dirname \$f)\"; cp -a \"\$f\" \"$MNT\$f\"; echo \"kept \$f\"; done
done; unset IFS
if [ -f /root/.ssh/authorized_keys ]; then mkdir -p $MNT/root/.ssh; chmod 700 $MNT/root/.ssh; cp -a /root/.ssh/authorized_keys $MNT/root/.ssh/; echo 'kept authorized_keys'; fi
if [ ! -d $MNT/usr/lib/modules/$rel ]; then
	if [ -d /usr/lib/modules/$rel ]; then mkdir -p $MNT/usr/lib/modules; cp -a /usr/lib/modules/$rel $MNT/usr/lib/modules/; echo 'copied modules $rel'
	else echo 'WARNING: no modules for $rel on the running root either; run push-kernel.sh (without --no-modules) first, then this script'; fi
fi
sync"
cleanup

echo "== grub default -> $other"
r 'mountpoint -q /boot || mount /boot' >/dev/null 2>&1 || true
r "set -e
cfg=/boot/grub/grub.cfg
# first normal (non-rescue) entry for $other = the newest kernel
n=\$(awk '/^menuentry /{ if (index(\$0, \"(root=$other)\") && !index(\$0, \"(rescue)\")) { print i+0; exit } i++ }' \$cfg)
if [ -z \"\$n\" ]; then echo 'WARNING: no (root=$other) entry in grub.cfg, default NOT changed (run push-kernel.sh --ab first)' >&2; exit 1; fi
cp -n \$cfg \$cfg.before-rootfs-push
sed -i \"s/^set default=.*/set default=\$n/\" \$cfg && sync
echo \"grub default is now entry \$n:\"; awk -v n=\$n '/^menuentry /{ if (i++ == n) print }' \$cfg"

echo; echo "Reboot to boot it. If it fails, pick the (root=$cur) entry in the GRUB menu, or run tools/set-grub-default.sh."
