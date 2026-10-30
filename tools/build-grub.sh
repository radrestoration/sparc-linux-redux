#!/usr/bin/env bash
# Build GRUB for sparc64-ieee1275 on an x86 host (host tools + sparc64 modules).
# Result: $ROOT/build/grub-root/{bin,sbin,lib/grub/sparc64-ieee1275}
#
# needs: sparc64-linux-gnu-gcc, bison, flex, gawk, make, curl, gpg
# usage: tools/build-grub.sh            (version via GRUB_VER, default 2.14)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=${GRUB_VER:-2.14}
B=$ROOT/build
KEY=BE5C23209ACDDACEB20DB0A28C8189F1988C2166   # Daniel Kiper, GRUB release signing key

for t in sparc64-linux-gnu-gcc bison flex gawk make curl gpg; do
	command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

mkdir -p "$B/dl" "$B/src"
cd "$B/dl"
for f in grub-$VER.tar.xz grub-$VER.tar.xz.sig; do
	[ -f "$f" ] || curl -sfLO "https://ftp.gnu.org/gnu/grub/$f"
done

# verify in a throwaway keyring so the user's own keyring is untouched
export GNUPGHOME=$(mktemp -d); chmod 700 "$GNUPGHOME"; trap 'rm -rf "$GNUPGHOME"' EXIT
gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys "$KEY"
gpg --status-fd 1 --verify grub-$VER.tar.xz.sig grub-$VER.tar.xz 2>/dev/null | grep -q "VALIDSIG .* $KEY" ||
	{ echo "signature check FAILED" >&2; exit 1; }
echo "signature ok"

[ -d "$B/src/grub-$VER" ] || tar -xf grub-$VER.tar.xz -C "$B/src"

# local fixes (tools/patches/grub-$VER-*.patch), applied once; see each patch for why
for p in "$ROOT"/tools/patches/grub-$VER-*.patch; do
	[ -e "$p" ] || continue
	if patch -p1 -R --dry-run -s -d "$B/src/grub-$VER" <"$p" >/dev/null 2>&1; then
		echo "patch already applied: $(basename "$p")"
	else
		patch -p1 -d "$B/src/grub-$VER" <"$p" && echo "applied: $(basename "$p")"
	fi
done

mkdir -p "$B/grub-sparc64" && cd "$B/grub-sparc64"
[ -f Makefile ] || "$B/src/grub-$VER/configure" --target=sparc64-linux-gnu --with-platform=ieee1275 \
	--disable-werror --disable-nls --disable-grub-mkfont --disable-grub-themes \
	--disable-device-mapper --disable-libzfs --prefix="$B/grub-root" >configure.log 2>&1
make -j"$(nproc)" >make.log 2>&1
make install >install.log 2>&1
echo "built -> $B/grub-root"
