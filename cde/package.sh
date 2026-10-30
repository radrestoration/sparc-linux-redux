#!/usr/bin/env bash
# Turn build/cde/cde-sparc64.tar.gz (from cde/stage.sh) into Debian packages: build/cde/deb/*.deb
#
#   cde/package.sh [--version V]       default version: 2.5.3-1
#
# No recompiling: the packages are cut from the already built tree with dpkg-deb. Two packages:
#   cde-desktop   the programs, libraries, configuration, PAM files (everything but the help text)
#   cde-help      the help volumes and the online manuals (usr/dt/infolib, usr/dt/appconfig/help); cde-desktop recommends it
# Dependencies on Debian libraries are worked out from the programs' own needed-library entries (readelf), looked up with dpkg -S inside
# the build chroot; the extra runtime tools CDE calls (ksh, rpcbind, ncompress, fonts ...) are listed in RUNTIME_DEPS below.
# Set CDE_MAINTAINER="Name <mail>" to change the Maintainer field.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/${CDE_DIR:-cde}
TARBALL=$WORK/cde-sparc64.tar.gz
OUT=$WORK/deb
TMP=$WORK/pkgwork
VERSION=2.5.3-1
MAINT=${CDE_MAINTAINER:-Ultra 10 Linux project <ultra10@localhost>}
# what CDE's scripts and daemons run, that no ELF file's library list shows (verified against the install: ksh scripts use /usr/bin/ksh,
# the portmapper for ToolTalk and the session, ncompress for the help/icon tools, X resources and bitmaps, bitmap fonts, Tcl for dtksh/dtscript)
RUNTIME_DEPS="ksh93u+m, rpcbind, ncompress, x11-xserver-utils, xbitmaps, xfonts-75dpi, xfonts-100dpi, tcl8.6, libpam-modules"

while [ $# -gt 0 ]; do case $1 in --version) VERSION=$2; shift 2;; *) echo "unknown option: $1" >&2; exit 1;; esac; done
[ -f "$TARBALL" ] || { echo "ERROR: $TARBALL missing: cde/stage.sh" >&2; exit 1; }
for t in dpkg-deb sparc64-linux-gnu-readelf; do command -v "$t" >/dev/null || { echo "ERROR: missing tool: $t" >&2; exit 1; }; done

rm -rf --one-file-system "$TMP" "$OUT"; mkdir -p "$TMP/all" "$TMP/help" "$OUT"
tar -C "$TMP/all" -xzf "$TARBALL"

# ---- split off the help package
mkdir -p "$TMP/help/usr/dt/appconfig"
mv "$TMP/all/usr/dt/infolib" "$TMP/help/usr/dt/infolib"
mv "$TMP/all/usr/dt/appconfig/help" "$TMP/help/usr/dt/appconfig/help"

# ---- library dependencies: sonames the programs need, minus the ones CDE itself provides, mapped to Debian packages
own=$(cd "$TMP/all/usr/dt/lib" && ls | grep -E '\.so\.[0-9]+$' || true)
: >"$TMP/needed"
while IFS= read -r -d '' f; do
	[ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
	sparc64-linux-gnu-readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' >>"$TMP/needed"
done < <(find "$TMP/all" -type f -print0)
sort -u "$TMP/needed" | grep -vxF "$own" >"$WORK/sonames.txt"
"$ROOT/cde/chroot.sh" run sh -c 'while read -r so; do
		p=$(dpkg -S "*/$so" 2>/dev/null | head -1 | sed "s/:.*//; s/:[a-z0-9]*\$//")
		[ -n "$p" ] && echo "$p" || echo "UNRESOLVED:$so"
	done </work/sonames.txt' | sort -u >"$TMP/libpkgs"
if grep -q UNRESOLVED "$TMP/libpkgs"; then echo "ERROR: libraries with no Debian package:" >&2; grep UNRESOLVED "$TMP/libpkgs" >&2; exit 1; fi
LIBDEPS=$(paste -sd, "$TMP/libpkgs" | sed 's/,/, /g')

# ---- one package
mkpkg() {   # name dir description-short description-long depends [recommends]
	local name=$1 dir=$2 short=$3 long=$4 dep=$5 rec=${6:-}
	mkdir -p "$dir/DEBIAN"
	local size; size=$(du -sk --exclude=DEBIAN "$dir" | cut -f1)
	{
		echo "Package: $name"; echo "Version: $VERSION"; echo "Architecture: sparc64"; echo "Maintainer: $MAINT"
		echo "Installed-Size: $size"; echo "Section: x11"; echo "Priority: optional"
		echo "Homepage: https://sourceforge.net/projects/cdesktopenv/"
		[ -z "$dep" ] || echo "Depends: $dep"
		[ -z "$rec" ] || echo "Recommends: $rec"
		echo "Description: $short"; echo " $long"
	} >"$dir/DEBIAN/control"
	dpkg-deb --root-owner-group -Zxz --build "$dir" "$OUT/${name}_${VERSION}_sparc64.deb" >/dev/null
}

# dtlogin's LSB init script (from the CDE source: contrib/rc/linux). Installed but not enabled: it competes with xdm for display :0, so
# the image build (build-debian.sh --with-cde) or the administrator decides:  update-rc.d dtlogin defaults
mkdir -p "$TMP/all/etc/init.d"
install -m755 "$WORK/src/cde/contrib/rc/linux/dtlogin" "$TMP/all/etc/init.d/dtlogin"
cat >"$TMP/all/.postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
	ldconfig
	mkdir -p /var/dt /etc/dt/config
fi
exit 0
EOF
cat >"$TMP/all/.postrm" <<'EOF'
#!/bin/sh
set -e
case "$1" in remove|purge) ldconfig;; esac
exit 0
EOF
mkdir -p "$TMP/all/DEBIAN"
install -m755 "$TMP/all/.postinst" "$TMP/all/DEBIAN/postinst"; install -m755 "$TMP/all/.postrm" "$TMP/all/DEBIAN/postrm"; rm "$TMP/all/.postinst" "$TMP/all/.postrm"
# files below /etc are configuration the administrator may edit
( cd "$TMP/all" && find etc -type f | sed 's|^|/|' | grep -v '/etc/ld.so.conf.d/' >DEBIAN/conffiles ) || true
[ -s "$TMP/all/DEBIAN/conffiles" ] || rm -f "$TMP/all/DEBIAN/conffiles"

mkpkg cde-desktop "$TMP/all" "Common Desktop Environment (CDE)" \
	"The classic Unix desktop: window manager (dtwm), session, login manager, file manager, terminal, editor and the rest, installed under /usr/dt. Built from the CDE 2.5.3 source for sparc64." \
	"$LIBDEPS, $RUNTIME_DEPS" "cde-help"
mkpkg cde-help "$TMP/help" "Help volumes and manuals for the Common Desktop Environment" \
	"The online help volumes and user guides for CDE (usr/dt/infolib and usr/dt/appconfig/help)." \
	"cde-desktop (= $VERSION)"

rm -rf --one-file-system "$TMP"
for d in "$OUT"/*.deb; do echo "== $(basename "$d")  $(du -h "$d" | cut -f1)"; dpkg-deb -f "$d" Depends | tr ',' '\n' | sed 's/^ */   /'; done
