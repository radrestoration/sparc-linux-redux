#!/usr/bin/env bash
# Cross-build a sparc64 Linux kernel on this (x86) host: download + verify, configure from a base config plus a
# fragment, build vmlinux + modules, stage everything under build/kernel/out/<name>/.
#
# usage: tools/build-kernel.sh [config|build|all]      (default: all)
# env:   KVER=7.3   BASE=<base .config>   FRAGMENT=<fragment>   NAME=ultra10
# result: build/kernel/out/$KVER-$NAME/{vmlinux,System.map,config,modules/lib/modules/<release>}
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KVER=${KVER:-7.3}
NAME=${NAME:-ultra10}
BASE=${BASE:-$ROOT/tools/kernel/base-config-debian-6.18.5-sparc64.config}     # Debian's sparc64 kernel config, the starting point
FRAGMENT=${FRAGMENT:-$ROOT/tools/kernel/ultra10.fragment}
K=$ROOT/build/kernel
SRC=$K/src/linux-$KVER
OBJ=$K/obj-$KVER-$NAME            # out-of-tree build dir keeps the source pristine
OUT=$K/out/$KVER-$NAME
MAKE=(make -C "$SRC" O="$OBJ" ARCH=sparc64 CROSS_COMPILE=sparc64-linux-gnu-)
step=${1:-all}

fetch() {
	[ -d "$SRC" ] && return 0
	mkdir -p "$K/dl" "$K/src"
	local major=${KVER%%.*} base=https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x
	( cd "$K/dl"
	  [ -f linux-$KVER.tar.xz ] || curl -sfLO "$base/linux-$KVER.tar.xz"
	  [ -f linux-$KVER.tar.sign ] || curl -sfLO "$base/linux-$KVER.tar.sign"
	  [ -f linux-$KVER.tar ] || xz -dk linux-$KVER.tar.xz
	  export GNUPGHOME=$(mktemp -d); chmod 700 "$GNUPGHOME"
	  for k in 647F28654894E3BD457199BE38DBBDC86092693E ABAF11C65A2970B130ABE3C479BE3E4300411886; do   # Greg KH, Linus
		gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys $k 2>/dev/null || true
	  done
	  gpg --status-fd 1 --verify linux-$KVER.tar.sign linux-$KVER.tar 2>/dev/null | grep -q '^\[GNUPG:\] GOODSIG' ||
		{ echo "kernel signature check FAILED" >&2; exit 1; }
	  echo "kernel signature ok" )
	tar -xf "$K/dl/linux-$KVER.tar" -C "$K/src"
}

# local fixes (tools/patches/linux-$KVER-*.patch), applied once; see each patch for why
apply_patches() {
	local p
	for p in "$ROOT"/tools/patches/linux-$KVER-*.patch; do
		[ -e "$p" ] || continue
		if patch -p1 -R --dry-run -s -d "$SRC" <"$p" >/dev/null 2>&1; then echo "patch already applied: $(basename "$p")"
		else patch -p1 -s -d "$SRC" <"$p" && echo "applied: $(basename "$p")"; fi
	done
}

configure() {
	fetch
	apply_patches
	mkdir -p "$OBJ"
	cp "$BASE" "$OBJ/.config"
	"$SRC/scripts/kconfig/merge_config.sh" -m -O "$OBJ" "$OBJ/.config" "$FRAGMENT" >"$OBJ/merge.log" 2>&1 || { tail -20 "$OBJ/merge.log"; exit 1; }
	"${MAKE[@]}" olddefconfig >"$OBJ/olddefconfig.log" 2>&1 || { tail -20 "$OBJ/olddefconfig.log"; exit 1; }
	# report whether each fragment setting survived (dependencies can override it)
	grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)' "$FRAGMENT" | while read -r line; do
		sym=$(echo "$line" | sed -E 's/^# (CONFIG_[A-Z0-9_]+) is not set/\1/; s/^(CONFIG_[A-Z0-9_]+)=.*/\1/')
		got=$(grep -E "^(# )?$sym[= ]" "$OBJ/.config" | head -1 || true)
		[ -n "$got" ] || got="# $sym (absent: dependency not met)"
		want=$line; [ "$got" = "$want" ] || echo "NOTE: wanted '$want' got '$got'"
	done
	echo "configured -> $OBJ/.config"
}

build() {
	[ -f "$OBJ/.config" ] || configure
	apply_patches
	"${MAKE[@]}" -j"$(nproc)" vmlinux modules >"$OBJ/build.log" 2>&1 || { tail -30 "$OBJ/build.log"; exit 1; }
	rel=$("${MAKE[@]}" -s kernelrelease)
	mkdir -p "$OUT"
	"${MAKE[@]}" modules_install INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1 >"$OBJ/modules_install.log" 2>&1
	cp "$OBJ/System.map" "$OUT/System.map"; cp "$OBJ/.config" "$OUT/config"
	# GRUB loads the ELF program headers only; symbols are not needed at run time (kallsyms is built in)
	sparc64-linux-gnu-strip --strip-all -o "$OUT/vmlinux" "$OBJ/vmlinux"
	echo "$rel" >"$OUT/release"
	ls -l "$OUT/vmlinux" | awk '{print "vmlinux:",$5,"bytes"}'
	echo "built $rel -> $OUT"
}

case $step in
	config) configure;;
	build) build;;
	all) configure; build;;
	*) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 1;;
esac
