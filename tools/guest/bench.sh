#!/bin/sh
# Quick snapshot of kernel, memory and disk behaviour on the Ultra 10, same output on every distro/kernel so runs can be
# compared. POSIX sh, reads /proc and /sys only (no procps/free needed). Run as root:   sh bench.sh
echo "== kernel"
uname -srm
cut -c1-100 /proc/cmdline
echo "== uptime (seconds since boot)"
cut -d' ' -f1 /proc/uptime
echo "== memory (kB)"
grep -E '^(MemTotal|MemFree|MemAvailable|Cached|SwapTotal|SwapFree|Slab|PageTables):' /proc/meminfo
echo "== processes: $(ls -d /proc/[0-9]* 2>/dev/null | wc -l)"
echo "== disk transfer mode"
for f in /sys/class/ata_device/dev*/xfer_mode; do [ -r "$f" ] && echo "$(basename "$(dirname "$f")"): $(cat "$f")"; done
echo "== read 100 MB from the root partition"
dd if=/dev/sda4 of=/dev/null bs=1M count=100 2>&1 | tail -1
echo "== kernel messages"
echo "lost interrupt / timeout / I/O error lines: $(dmesg | grep -ciE 'lost interrupt|timeout|i/o error')"
dmesg | grep -iE 'limiting speed' | head -3
dmesg | grep -iE -m4 'atyfb|ffb|fb0|Memory:'
echo "== done"
