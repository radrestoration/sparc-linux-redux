#!/usr/bin/env bash
# Install the built CDE into a staging tree and prepare it for the Ultra: build/cde/stage (to unpack onto a sparc64 root filesystem).
#
#   cde/stage.sh [--no-strip] [--dev] [--keep]
#
# Needs cde/build.sh to have finished. The install runs in the chroot (CDE's own make install, with DESTDIR). Afterwards, on the PC:
#   - ELF files are stripped (sparc64-linux-gnu-strip), since the build is -g and the Ultra's disk is small
#   - etc/ld.so.conf.d/cde.conf adds /usr/dt/lib (the programs carry no RPATH); run ldconfig on the target after unpacking
#   - static libraries, libtool .la files and headers are dropped (build-time only; --dev keeps them)
#   - the dangling usr/dt/man link is removed (the Ultra image carries no man pages)
# Result: build/cde/cde-sparc64.tar.gz, unpacked only when an image is built (tar -C ROOTFS -xzf ...). The loose staging tree is deleted
# afterwards unless --keep is given.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/${CDE_DIR:-cde}
STAGE=$WORK/stage
STRIP=1 DEV=0 KEEP=0
for a in "$@"; do case $a in --no-strip) STRIP=0;; --dev) DEV=1;; --keep) KEEP=1;; *) echo "unknown option: $a" >&2; exit 1;; esac; done

[ -f "$WORK/src/cde/programs/dtwm/.libs/dtwm" ] || { echo "ERROR: not built yet: cde/build.sh" >&2; exit 1; }
command -v sparc64-linux-gnu-strip >/dev/null || { echo "ERROR: sparc64-linux-gnu-strip missing (binutils-sparc64-linux-gnu)" >&2; exit 1; }

rm -rf --one-file-system "$STAGE"
"$ROOT/cde/chroot.sh" run sh -c 'export LC_ALL=C.UTF-8; cd /work/src/cde && make install DESTDIR=/work/stage' >"$WORK/install.log" 2>&1 \
	|| { tail -20 "$WORK/install.log" >&2; exit 1; }

if [ "$STRIP" = 1 ]; then
	n=0
	while IFS= read -r -d '' f; do
		[ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
		sparc64-linux-gnu-strip --strip-unneeded "$f" 2>/dev/null && n=$((n+1))
	done < <(find "$STAGE" -type f -print0)
	echo "stripped $n ELF files"
fi

[ "$DEV" = 1 ] || { find "$STAGE" \( -name '*.a' -o -name '*.la' \) -delete; rm -rf "$STAGE/usr/dt/include"; }
mkdir -p "$STAGE/etc/ld.so.conf.d"
echo /usr/dt/lib >"$STAGE/etc/ld.so.conf.d/cde.conf"
[ -e "$STAGE/usr/dt/man" ] || rm -f "$STAGE/usr/dt/man"
find "$STAGE" -xtype l -print -delete | sed 's/^/removed dangling link: /'

du -sh "$STAGE" | sed 's/^/unpacked size: /'
tar -C "$STAGE" --owner=0 --group=0 -cf - . | gzip -9n >"$WORK/cde-sparc64.tar.gz"
[ "$KEEP" = 1 ] || rm -rf --one-file-system "$STAGE"
ls -lh "$WORK/cde-sparc64.tar.gz"
