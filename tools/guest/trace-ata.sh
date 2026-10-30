#!/bin/sh
# Show what libata REALLY does for a read: which protocol each command uses (PIO or DMA), whether the bus-master DMA engine
# is started, and how commands complete or fail. Uses the kernel's libata trace events (needs a kernel with tracing + debugfs).
# Read-only on the device: it just reads from it with dd. Run as root on the Ultra 10, from the PC with ONE ssh/password:
#   ssh root@192.168.2.20 'sh -s -- /dev/sr0 100' < tools/guest/trace-ata.sh
#   ssh root@192.168.2.20 'sh -s -- /dev/sda4 20' < tools/guest/trace-ata.sh        (SSD, 64 KB blocks)
DEV=${1:-/dev/sr0}; N=${2:-100}
EV="ata_qc_issue ata_bmdma_start ata_bmdma_stop ata_qc_complete_done ata_qc_complete_failed"

T=/sys/kernel/tracing
[ -d "$T/events" ] || { mkdir -p "$T"; mount -t tracefs nodev "$T" 2>/dev/null; }
if [ ! -d "$T/events" ]; then
	[ -d /sys/kernel/debug/tracing/events ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
	T=/sys/kernel/debug/tracing
fi
[ -d "$T/events/libata" ] || { echo "no libata trace events under $T (tracing not available?)" >&2; exit 1; }

echo "== device"; echo "$DEV: $(ls -l "$DEV" | cut -c1-60)"
for d in /sys/class/ata_device/dev*; do echo "$(basename "$d"): xfer_mode=$(cat "$d/xfer_mode") pio_mode=$(cat "$d/pio_mode") dma_mode=$(cat "$d/dma_mode")"; done
b=$(basename "$DEV" | sed 's/[0-9]*$//'); [ -r "/sys/block/$b/queue/max_sectors_kb" ] && echo "$b: max_sectors_kb=$(cat /sys/block/$b/queue/max_sectors_kb) max_segments=$(cat /sys/block/$b/queue/max_segments)"

echo 0 >"$T/tracing_on"; : >"$T/trace"
for e in $EV; do echo 1 >"$T/events/libata/$e/enable" 2>/dev/null || echo "(event $e not available)"; done
irq0=$(awk '/pata_cmd64x/{print $2; exit}' /proc/interrupts)
echo 1 >"$T/tracing_on"
echo "== reading $N x 64 KB from $DEV"
dd if="$DEV" of=/dev/null bs=64k count="$N" 2>&1 | tail -1
echo 0 >"$T/tracing_on"
irq1=$(awk '/pata_cmd64x/{print $2; exit}' /proc/interrupts)
for e in $EV; do echo 0 >"$T/events/libata/$e/enable" 2>/dev/null; done

echo "== interrupts during the read: $((irq1 - irq0))"
echo "== commands issued, by protocol"; grep -o 'proto=[A-Z_]*' "$T/trace" | sort | uniq -c
echo "== events: issue=$(grep -c ' ata_qc_issue:' "$T/trace")  bmdma_start=$(grep -c ' ata_bmdma_start:' "$T/trace")  bmdma_stop=$(grep -c ' ata_bmdma_stop:' "$T/trace")  complete_done=$(grep -c ' ata_qc_complete_done:' "$T/trace")  complete_FAILED=$(grep -c ' ata_qc_complete_failed:' "$T/trace")"
echo "== first commands"; grep ' ata_qc_issue:' "$T/trace" | head -4 | cut -c1-200
echo "== any failures"; grep ' ata_qc_complete_failed:' "$T/trace" | head -3 | cut -c1-200
: >"$T/trace"
