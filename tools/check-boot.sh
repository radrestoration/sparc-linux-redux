#!/usr/bin/env bash
# READ-ONLY check of a GRUB sparc64 boot partition written by prepare-disk.sh: does the boot block
# (sector 1 of the partition) point at the real location of core.img?
#
# usage: sudo tools/check-boot.sh /dev/sdX1 [path-of-core.img-inside-fs]
#   default path: /grub/sparc64-ieee1275/core.img
# Reads the device with dd/debugfs only; never writes.
set -euo pipefail

part=${1:?usage: $0 /dev/sdX1 [core.img path in fs]}
core=${2:-/grub/sparc64-ieee1275/core.img}
[ -b "$part" ] || { echo "$part is not a block device" >&2; exit 1; }
[ "$(lsblk -dno TYPE "$part")" = part ] || { echo "$part is a whole disk; give the boot PARTITION (e.g. ${part}1)" >&2; exit 1; }
if lsblk -no MOUNTPOINTS "$part" | grep -q .; then echo "note: $part is mounted (reads are still fine)"; fi

rd() { dd if="$part" bs=1 skip="$1" count="$2" status=none; }          # read bytes at byte offset
be64() { od -An -tx1 -v | tr -d ' \n' | sed 's/^/0x/'; }

echo "== partition sectors 0-1 (first 64 bytes of each)"
for s in 0 1; do echo "sector $s:"; rd $((s * 512)) 64 | xxd; done

magic=$(rd 512 4 | od -An -tx1 | tr -d ' \n')
echo
echo "boot block a.out magic at sector 1: $magic   (expect 01030107 = SunOS sparc a.out)"
devpath=$(rd $((512 + 32 + 0x08)) 120 | tr -d '\0' | head -c 120 || true)
echo "embedded boot device path: '${devpath}'   (expect empty for a same-disk install)"
kbyte=$(rd $((512 + 32 + 0x80)) 8 | be64)
echo "kernel_byte in boot block: $kbyte = $((kbyte)) bytes -> sector $(( kbyte / 512 )) of the partition"

echo
echo "== core.img as the filesystem sees it"
bs=$(debugfs -R "stats -h" "$part" 2>/dev/null | awk '/^Block size:/ {print $3}')
blk=$(debugfs -R "bmap $core 0" "$part" 2>/dev/null | tail -1)
echo "fs block size: ${bs:-?}   first block of $core: ${blk:-?}"
if [ -n "${bs:-}" ] && [ -n "${blk:-}" ] && [ "$blk" -gt 0 ] 2>/dev/null; then
	want=$(( blk * bs ))
	echo "core.img starts at byte $want (sector $(( want / 512 )))"
	if [ "$want" -eq $((kbyte)) ]; then echo "MATCH: boot block points at core.img"; else echo "MISMATCH: boot block says $((kbyte)), file is at $want"; fi
	tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
	debugfs -R "dump $core $tmp" "$part" >/dev/null 2>&1 || true
	a=$(head -c 512 "$tmp" | md5sum | cut -c1-32)
	b=$(rd "$want" 512 | md5sum | cut -c1-32)
	echo "first 512 bytes of core.img: file=$a  on-disk-at-that-offset=$b  $([ "$a" = "$b" ] && echo same || echo DIFFERENT)"
	echo "core.img size: $(stat -c%s "$tmp") bytes"
	echo
	echo "== diskboot blocklist inside core.img (what the 2nd stage will actually read)"
	python3 -I - "$tmp" "$bs" "$part" <<'PY'
import struct, sys
core, bs, devpath = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = open(core, 'rb').read()
size = len(d)
# entries sit at the end of sector 0, growing downward, 12 bytes each: u64 start (sectors), u32 len (sectors), big endian;
# the 2nd stage (diskboot) reads them in this order, seeking to start*512 within the boot slice
ents, off = [], 512 - 12
while off >= 0:
    start, ln = struct.unpack('>QI', d[off:off + 12])
    if ln == 0:
        break
    ents.append((start, ln)); off -= 12
min_need = (size + 511) // 512 - 1                       # sectors after diskboot
max_need = -(-size // bs) * (bs // 512) - 1              # GRUB lists whole filesystem blocks
total = sum(l for _, l in ents)
print("entries (start sector in slice, length in sectors), in the order they are read:")
for s_, l_ in ents:
    print("  %10d  %10d%s" % (s_, l_, "   <-- absurd length" if l_ > max_need else ""))
print("total sectors listed: %d   expected %d..%d   %s" % (total, min_need, max_need, "OK" if min_need <= total <= max_need else "WRONG"))
# do exactly what diskboot does: read each run from the device and glue it after sector 0
dev = open(devpath, 'rb')
out = bytearray(d[:512])
for s_, l_ in ents:
    if l_ > max_need:
        break
    dev.seek(s_ * 512)
    out += dev.read(l_ * 512)
if out[:size] == d:
    print("reassembled from the blocklist, read off the device: IDENTICAL to core.img  -> the 2nd stage will load the right data")
else:
    first = next((i for i in range(min(len(out), size)) if out[i] != d[i]), min(len(out), size))
    print("reassembled data DIFFERS from core.img (first difference at byte %d, got %d bytes of %d)" % (first, len(out), size))
PY
else
	echo "could not find $core in the filesystem (wrong path, or filesystem empty?)"
fi
echo
echo "== files in the grub dir"
debugfs -R "ls -l /grub/sparc64-ieee1275" "$part" 2>/dev/null | grep -E "core.img|boot.img|device.map|kernel.img" || true
debugfs -R "ls -l /grub" "$part" 2>/dev/null | grep -E "grub.cfg" || true
