#!/usr/bin/env bash
# A sparc64 Debian sid build chroot, run through qemu-user, for compiling CDE (and anything else) without touching the Ultra.
#
#   cde/chroot.sh create          bootstrap the chroot (once; ~30-60 min under emulation)
#   cde/chroot.sh run CMD...      run CMD in it, as root of a user namespace (no sudo)
#   cde/chroot.sh shell           interactive shell
#   cde/chroot.sh destroy         remove it
#
# CDE_DIR=name uses build/name and its own chroot instead (default: cde).
# The project's build/cde directory appears inside the chroot as /work, so sources and results live in the project, owned by you.
# The chroot itself is in /var/tmp (its files belong to subuids, so plain rm and tar of the project cannot cope with them).
# Same requirements as tools/build-debian.sh (debootstrap, qemu-user-binfmt with the F flag, a /etc/subuid range).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=${CDE_DIR:-cde}      # CDE_DIR=other keeps a second, independent chroot and work directory (clean-build tests)
SHARE=$ROOT/build/$NAME
REAL_USER=${CDE_REAL_USER:-$(id -un)}      # inside the user namespace id -un says root
CH=/var/tmp/ultra10-$NAME-chroot-$REAL_USER
MIRROR=http://deb.debian.org/debian-ports
KEYRING=/usr/share/keyrings/debian-ports-archive-keyring.gpg
PKGS=mount,liblmdb-dev,opensp,libcrypt-dev,build-essential,git,pkgconf,ca-certificates,autoconf,automake,libtool,m4,bison,flex,gettext,patch,python3,ncompress,rpcsvc-proto,\
ksh93u+m,libmotif-dev,libx11-dev,libxt-dev,libxext-dev,libxft-dev,libxpm-dev,libxinerama-dev,libxss-dev,libxmu-dev,libxaw7-dev,\
libxrender-dev,libxtst-dev,libxdmcp-dev,libxau-dev,libxkbfile-dev,libtirpc-dev,libpam0g-dev,libutempter-dev,libssl-dev,libjpeg-dev,\
libfreetype-dev,libfontconfig-dev,libncurses-dev,tcl8.6-dev,libbsd-dev,x11proto-dev,xtrans-dev,xbitmaps,x11-xserver-utils,\
xfonts-100dpi,xfonts-100dpi-transcoded,xfonts-75dpi,xfonts-75dpi-transcoded

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# re-run this script as "root" in a user namespace (0 -> you, 1.. -> your /etc/subuid range)
enter_userns() {
	[ "$(id -u)" != 0 ] || return 0
	grep -q "^$(id -un):" /etc/subuid || die "no /etc/subuid range for $(id -un)"
	CDE_REAL_USER=$REAL_USER exec unshare --map-auto --map-root-user --mount --pid --fork "$0" "$@"
}

check() {
	for t in debootstrap unshare; do command -v "$t" >/dev/null || die "missing tool: $t"; done
	[ -f "$KEYRING" ] || die "$KEYRING missing (debian-ports-archive-keyring)"
	grep -q '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-sparc64 2>/dev/null || die "qemu-sparc64 binfmt not registered with the F flag"
}

mounts() {
	mkdir -p "$CH/proc" "$CH/dev" "$CH/work" "$SHARE"
	mount -t proc proc "$CH/proc"
	mount --rbind /dev "$CH/dev"; mount --make-rslave "$CH/dev"
	mount --bind "$SHARE" "$CH/work"
	cp -L /etc/resolv.conf "$CH/etc/resolv.conf" 2>/dev/null || true
}

cmd=${1:-}; shift || true
case $cmd in
create)
	enter_userns create; check
	[ ! -e "$CH" ] || die "$CH exists: cde/chroot.sh destroy first"
	mkdir -p "$CH"
	say "debootstrap stage 1 (download, unpack)"
	debootstrap --foreign --arch=sparc64 --variant=buildd --keyring="$KEYRING" --include="$PKGS" sid "$CH" "$MIRROR"
	# stage 1 unpacks only the required packages and leaves the rest to stage 2, so the chroot has no libc for some binaries yet:
	# unpack every downloaded package now (dpkg --unpack in stage 2 overwrites them), as tools/build-debian.sh does
	for d in "$CH"/var/cache/apt/archives/*.deb; do dpkg-deb --fsys-tarfile "$d" | tar --keep-directory-symlink -xf - -C "$CH"; done
	say "stage 2 (package configuration under qemu-user)"
	mkdir -p "$CH/proc" "$CH/dev"
	mount -t proc proc "$CH/proc"; mount --rbind /dev "$CH/dev"; mount --make-rslave "$CH/dev"
	printf '#!/bin/sh\nexit 101\n' >"$CH/usr/sbin/policy-rc.d"; chmod 755 "$CH/usr/sbin/policy-rc.d"
	mkdir -p "$CH/etc/dpkg/dpkg.cfg.d"; echo force-unsafe-io >"$CH/etc/dpkg/dpkg.cfg.d/02_unsafe_io"
	chroot "$CH" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb LC_ALL=C DEBIAN_FRONTEND=noninteractive \
		/debootstrap/debootstrap --second-stage
	rm -f "$CH/usr/sbin/policy-rc.d"
	# apt inside the chroot, signature-checked against the ports keyring, for installing further build dependencies
	mkdir -p "$CH/usr/share/keyrings"; cp "$KEYRING" "$CH/usr/share/keyrings/"
	echo "deb [signed-by=/usr/share/keyrings/debian-ports-archive-keyring.gpg] $MIRROR sid main" >"$CH/etc/apt/sources.list"
	say "done: $CH"
	;;
run|shell)
	enter_userns "$cmd" "$@"
	[ -d "$CH/usr" ] || die "no chroot: cde/chroot.sh create"
	mounts
	[ "$cmd" = shell ] && set -- /bin/bash -l
	exec chroot "$CH" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-dumb}" \
		LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@"
	;;
destroy)
	enter_userns destroy
	[ -d "$CH" ] || exit 0
	grep -q " $CH" /proc/mounts && die "something is mounted under $CH"
	rm -rf --one-file-system "$CH"
	;;
*) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 1;;
esac
