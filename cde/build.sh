#!/usr/bin/env bash
# Build CDE (Common Desktop Environment) for sparc64 inside the qemu-user chroot made by cde/chroot.sh.
#
#   cde/build.sh            fetch the source (once), patch it, configure, build
#   cde/build.sh -s         the same but with a serial make (-j1), for debugging
#
# Source: https://github.com/cdesktopenv/cde, release 2.5.3, pinned by commit. Result: build/cde/src/cde (built in place; install is a
# separate step). Log: build/cde/build.log (CDE_DIR=name uses build/name and a separate chroot). Every workaround is here or in cde/patches:
#   -std=gnu17                  the chroot's GCC 16 defaults to C23, where foo() means foo(void); CDE's old code breaks
#   patches/*.patch             the bundled ksh93 uses "nullptr" as a variable name (a keyword in C23)
#   LC_ALL=C.UTF-8              the documentation is UTF-8 and the help compiler rejects it as invalid multi-byte text in the C locale
#   the DtMmdb pre-pass         its lexers include bison-generated headers, which a parallel make can build too late
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=${CDE_DIR:-cde}
WORK=$ROOT/build/$NAME
SRC=$WORK/src
COMMIT=e945fc8b08a4882769e29f20fbbb29afe6019da1       # tag 2.5.3
JOBS=8; [ "${1:-}" != -s ] || JOBS=1
TCL=/usr/lib/sparc64-linux-gnu/tcl8.6

if [ ! -d "$SRC/.git" ]; then
	mkdir -p "$WORK"
	git clone -q https://github.com/cdesktopenv/cde.git "$SRC"
fi
git -C "$SRC" checkout -q "$COMMIT"
for p in "$ROOT"/cde/patches/*.patch; do
	if git -C "$SRC" apply --check "$p" 2>/dev/null; then git -C "$SRC" apply "$p"; echo "applied $(basename "$p")"; fi
done

exec "$ROOT/cde/chroot.sh" run sh -c "
	set -e
	export LC_ALL=C.UTF-8
	cd /work/src/cde
	[ -x configure ] || ./autogen.sh
	[ -f Makefile ] || ./configure --with-tcl=$TCL CFLAGS='-g -O2 -std=gnu17' CXXFLAGS='-g -O2 -std=gnu++17'
	make -C lib/DtMmdb -j1 -k >/dev/null 2>&1 || true
	make -j$JOBS -k
" 2>&1 | tee "$WORK/build.log"
