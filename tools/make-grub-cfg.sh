#!/usr/bin/env bash
# Print a grub.cfg for every kernel found in a /boot directory (vmlinux-<release>), newest first.
#   - a kernel with a matching initrd.img-<release> boots with root=LABEL=rootfs + that initrd (Debian's modular kernel)
#   - a kernel without one must have the root drivers built in and boots with root=/dev/<ROOTDEV> (no label support
#     without an initramfs)
# Each kernel gets a normal entry and a rescue (single-user) entry.
#
# usage: tools/make-grub-cfg.sh BOOTDIR [--default REL] [--kargs "args"] [--rootdev sda4] [--dma-tests] [--ab]
#   --dma-tests  add two entries for the first (default) kernel: "PIO mode, no DMA" (libata.force=1.00:pio4, a safe mode for a drive
#                whose DMA times out) and "IDE trace" (libata's bus-master events recorded from boot, for debugging).
#                Do NOT force a DMA mode with libata.force=: it is re-applied on every reset, so a drive whose DMA fails can then
#                never fall back to PIO and the machine may not boot at all.
#   --ab         generate two sets of entries: one for root-a (LABEL=rootfs-a) and one for root-b (LABEL=rootfs-b)
set -euo pipefail

boot=${1:?usage: $0 BOOTDIR [--default REL] [--kargs ARGS] [--rootdev sda4]}; shift
default= kargs="rootwait" rootdev=sda4 dmatests=0 ab=0
while [ $# -gt 0 ]; do
	case $1 in
	--default) default=$2; shift 2;;
	--kargs) kargs=$2; shift 2;;
	--rootdev) rootdev=$2; shift 2;;
	--dma-tests) dmatests=1; shift;;
	--ab) ab=1; shift;;
	*) echo "unknown option: $1" >&2; exit 1;;
	esac
done

mapfile -t rels < <(cd "$boot" && ls vmlinux-* 2>/dev/null | sed 's/^vmlinux-//' | sort -rV)
[ "${#rels[@]}" -gt 0 ] || { echo "no vmlinux-* in $boot" >&2; exit 1; }

# put the requested default first
if [ -n "$default" ]; then
	ordered=("$default")
	for r in "${rels[@]}"; do [ "$r" = "$default" ] || ordered+=("$r"); done
	rels=("${ordered[@]}")
fi

echo "set default=0"
echo "set timeout=5"
for r in "${rels[@]}"; do
	[ -e "$boot/vmlinux-$r" ] || { echo "no such kernel: vmlinux-$r" >&2; exit 1; }
	
	if [ "$ab" = 1 ]; then
		# Generate entries for both rootfs-a and rootfs-b
		for label in rootfs-a rootfs-b; do
			if [ -e "$boot/initrd.img-$r" ]; then
				root="root=LABEL=$label"; initrd="initrd /initrd.img-$r"
			else
				# no label support without an initramfs: root-b is the partition after root-a
				dev=$rootdev; [ "$label" = rootfs-a ] || dev=${rootdev%[0-9]*}$(( ${rootdev##*[!0-9]} + 1 ))
				root="root=/dev/$dev"; initrd=""
			fi
			for variant in "" "single"; do
				title="Linux $r (root=$label)"; [ -z "$variant" ] || title="$title (rescue)"
				echo "menuentry \"$title\" {"
				echo "	linux /vmlinux-$r $root ro $kargs $variant"
				[ -z "$initrd" ] || echo "	$initrd"
				echo "}"
			done
		done
	else
		# Single rootfs
		if [ -e "$boot/initrd.img-$r" ]; then
			root="root=LABEL=rootfs"; initrd="initrd /initrd.img-$r"
		else
			root="root=/dev/$rootdev"; initrd=""
		fi
		for variant in "" "single"; do
			title="Linux $r"; [ -z "$variant" ] || title="$title (rescue)"
			echo "menuentry \"$title\" {"
			echo "	linux /vmlinux-$r $root ro $kargs $variant"
			[ -z "$initrd" ] || echo "	$initrd"
			echo "}"
		done
	fi
done

if [ "$dmatests" = 1 ]; then
	r=${rels[0]}
	if [ -e "$boot/initrd.img-$r" ]; then root="root=LABEL=rootfs"; initrd="initrd /initrd.img-$r"; else root="root=/dev/$rootdev"; initrd=""; fi
	base=$(printf '%s' "$kargs" | tr ' ' '\n' | grep -v '^libata.force=' | tr '\n' ' ')
	# a safe mode for a drive whose DMA does not work (a SATA bridge, say): PIO4 on the first channel's master, no DMA time-outs
	echo "menuentry \"Linux $r (PIO mode, no DMA)\" {"
	echo "	linux /vmlinux-$r $root ro $base libata.force=1.00:pio4"
	[ -z "$initrd" ] || echo "	$initrd"
	echo "}"
	# libata's own choice (no force) with the bus-master events traced from boot: the failures happen early, and the buffer then
	# holds the controller's DMA status (host_stat) at each failed command; read it with: cat /sys/kernel/tracing/trace.
	# Deliberately NOT forced: libata.force= pins the DMA mode on every reset, so a forced-DMA boot can never fall back to PIO
	ev=libata:ata_bmdma_start,libata:ata_bmdma_stop,libata:ata_bmdma_status,libata:ata_qc_complete_failed
	echo "menuentry \"Linux $r (IDE trace)\" {"
	echo "	linux /vmlinux-$r $root ro $base trace_event=$ev trace_buf_size=2M"
	[ -z "$initrd" ] || echo "	$initrd"
	echo "}"
fi
