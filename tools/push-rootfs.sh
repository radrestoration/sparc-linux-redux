#!/usr/bin/env bash
# Push a new rootfs built by tools/build-debian.sh onto the RUNNING Ultra 10 over ssh.
# Transfer rootfs.tar, unpack over / preserving /boot and /home, then sync.
#
# SAFE BY DEFAULT: without --go it only prints what it would do.
#
# usage: push-rootfs.sh --host root@192.168.2.20 [--rootfs-tar FILE] [--go]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST= ROOTFS= GO=0
while [ $# -gt 0 ]; do
	case $1 in
	--host) HOST=$2; shift 2;;
	--rootfs-tar) ROOTFS=$2; shift 2;;
	--go) GO=1; shift 1;;
	*) echo "unknown option: $1" >&2; exit 1;;
	esac
done

[ -n "$HOST" ] || { echo "ERROR: --host required" >&2; exit 1; }
[ -n "$ROOTFS" ] || ROOTFS=$ROOT/build/debian/rootfs.tar
[ -f "$ROOTFS" ] || { echo "ERROR: rootfs not found: $ROOTFS" >&2; exit 1; }

echo "Target: $HOST"
echo "Rootfs: $ROOTFS"
echo "Size: $(du -h "$ROOTFS" | cut -f1)"
echo

if [ $GO -eq 0 ]; then
	echo "[DRY RUN] Would:"
	echo "  1. Transfer $ROOTFS to /tmp on Ultra 10"
	echo "  2. Unpack over /, preserving /boot and /home"
	echo "  3. Sync filesystem"
	echo
	ssh "$HOST" 'echo "SSH OK: $(uname -n) ($(uname -r))"' || exit 1
	echo
	echo "Run with --go to actually push."
	exit 0
fi

echo "Transferring tarball..."
scp "$ROOTFS" "$HOST:/tmp/rootfs-push.tar"

echo "Unpacking..."
ssh "$HOST" bash << 'EOF'
set -e
TARBALL=/tmp/rootfs-push.tar
WORK=/tmp/rootfs-unpack

mkdir -p "$WORK"
cd "$WORK"
echo "Extracting..."
tar -xf "$TARBALL"

echo "Syncing to / (preserving /boot and /home)..."
for dir in bin etc lib lib64 opt root run sbin srv sys tmp usr var; do
	if [ -d "$dir" ]; then
		echo "  /$dir"
		"$WORK/bin/rm" -rf "/$dir"
		"$WORK/bin/mv" "$dir" /
	fi
done

echo "Cleaning up..."
"$WORK/bin/rm" -rf "$WORK" "$TARBALL"
sync

echo "Done."
EOF

echo
echo "Rootfs push complete."
