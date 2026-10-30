#!/usr/bin/env bash
# Prepare a disk for an OpenBoot (Sun UltraSPARC) Linux boot:
#   Sun disklabel -> filesystems -> unpack the root filesystem + install the kernel -> GRUB (sparc64-ieee1275) boot block.
#
# SAFE BY DEFAULT: without --go this only PRINTS what it would do. With --go it needs root and --confirm <name>, where <name>
# is the disk's basename (e.g. sda), so a pasted command cannot hit the wrong disk. It refuses the disk holding the running
# root filesystem and any disk with something mounted.
#
# Layout (Sun slices; slice 3 is the whole disk by Sun convention):
#   1  /boot   ext2   (must start at sector 0, see below; GRUB boots from it: openboot "boot disk")
#   2  swap
#   3  whole disk
#   4  /       ext4   (the rest, or with --ab: root-a)
#   5  /       ext4   (with --ab only: root-b)
#
# usage: prepare-disk.sh --disk /dev/sdX --rootfs-tar FILE --kernel-dir DIR [options] [--go --confirm sdX]
#   --rootfs-tar FILE   the root filesystem, from tools/build-debian.sh
#   --kernel-dir DIR    a kernel from tools/build-kernel.sh (vmlinux + modules; the boot-path drivers are built in: no initramfs)
#   --kargs "..."       kernel arguments (default: "rootwait", see below)
#   --default REL       which kernel release is GRUB's first entry (default: the newest)
#   --dma-tests         also add a "PIO mode, no DMA" and an "IDE trace" GRUB entry for the first kernel
#   --ab                create A/B partitions (root-a and root-b with shared boot and swap), both populated identically
#   --only a,b          run only some phases: label mkfs copy boot (default: all). 'label' and 'mkfs' DESTROY data;
#                       'copy' and 'boot' only write into the filesystems made earlier, so a mistake there can be repaired alone
#   --boot-mib N / --swap-mib N   slice sizes (default 512 / 1024)
#   --grub DIR          the GRUB install from tools/build-grub.sh (default: build/grub-root)
#   --mnt DIR           where the target is mounted while working (default /mnt/sparc-target)
#
# Kernel arguments: the default is just "rootwait". Some SATA-to-IDE bridge boards do not complete DMA on the Ultra 10's CMD646
# controller; libata then stalls ~30 s per failed command before it falls back to PIO. For such a drive pass
# --kargs "rootwait libata.force=1.00:pio4" (PIO4 on the first channel's master). Do not force a DMA mode: libata then cannot
# fall back to PIO and the machine may not boot.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DISK= TAR= KDIR= GO=0 CONFIRM= ONLY=label,mkfs,copy,boot GRUBDEF= DMATESTS=0 AB=0
BOOT_MIB=512 SWAP_MIB=1024
KARGS="rootwait"
GRUB=$ROOT/build/grub-root
MNT=/mnt/sparc-target
# ^orphan_file: keep root mountable by kernels older than 6.5.
# lazy_*=0: zero the inode tables and journal now, on the fast PC; otherwise the kernel's ext4lazyinit thread does it in the
# background on first mount, hammering a slow IDE link for a long time.
ROOT_MKFS_OPTS="-O ^orphan_file -E lazy_itable_init=0,lazy_journal_init=0"

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit "${1:-1}"; }
while [ $# -gt 0 ]; do
	case $1 in
	--disk) DISK=$2; shift 2;;
	--rootfs-tar) TAR=$2; shift 2;;
	--kernel-dir) KDIR=$2; shift 2;;
	--kargs) KARGS=$2; shift 2;;
	--default) GRUBDEF=$2; shift 2;;
	--dma-tests) DMATESTS=1; shift;;
	--ab) AB=1; shift;;
	--only) ONLY=$2; shift 2;;
	--boot-mib) BOOT_MIB=$2; shift 2;;
	--swap-mib) SWAP_MIB=$2; shift 2;;
	--grub) GRUB=$2; shift 2;;
	--mnt) MNT=$2; shift 2;;
	--go) GO=1; shift;;
	--confirm) CONFIRM=$2; shift 2;;
	-h|--help) usage 0;;
	*) echo "unknown option: $1" >&2; usage;;
	esac
done
has() { case ",$ONLY," in *,"$1",*) return 0;; esac; return 1; }

[ -n "$DISK" ] || usage
[ -b "$DISK" ] || { echo "$DISK is not a block device" >&2; exit 1; }
if has copy; then
	[ -n "$TAR" ] && [ -n "$KDIR" ] || { echo "the copy phase needs --rootfs-tar and --kernel-dir" >&2; usage; }
	[ -f "$TAR" ] || { echo "no such tarball: $TAR" >&2; exit 1; }
	KDIR=${KDIR%/}
	for f in vmlinux release config System.map; do [ -e "$KDIR/$f" ] || { echo "$KDIR/$f missing (run tools/build-kernel.sh)" >&2; exit 1; }; done
	[ -d "$KDIR/modules/lib/modules" ] || { echo "$KDIR/modules/lib/modules missing" >&2; exit 1; }
fi

# ---- safety checks -------------------------------------------------------------------------
name=$(basename "$DISK")
rootsrc=$(findmnt -no SOURCE / || true)
rootdisk=$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -1 || true)
[ "$name" != "${rootdisk:-}" ] && [ "$DISK" != "$rootsrc" ] || { echo "REFUSING: $DISK holds the running root filesystem" >&2; exit 1; }
if lsblk -no MOUNTPOINTS "$DISK" | grep -q .; then
	echo "REFUSING: something on $DISK is mounted:" >&2; lsblk -o NAME,MOUNTPOINTS "$DISK" >&2; exit 1
fi
bytes=$(lsblk -bdno SIZE "$DISK")
echo "target disk: $DISK  $(lsblk -dno SIZE,MODEL,TRAN "$DISK" | tr -s ' ')  ($bytes bytes)"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DISK"
[ "$bytes" -gt $(( (BOOT_MIB + SWAP_MIB + 4096) * 1048576 )) ] || { echo "disk too small for this layout" >&2; exit 1; }

if [ "$GO" = 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "--go needs root (sudo)" >&2; exit 1; }
	[ "$CONFIRM" = "$name" ] || { echo "--go also needs: --confirm $name" >&2; exit 1; }
else
	echo; echo "*** DRY RUN: nothing will be changed. Add: --go --confirm $name ***"
fi

run() { printf '+ %s\n' "$*"; if [ "$GO" = 1 ]; then "$@"; fi; }
pdev() { case $DISK in *[0-9]) echo "${DISK}p$1";; *) echo "${DISK}$1";; esac; }

# ---- geometry: Sun labels are in whole cylinders ---------------------------------------------
cyl=16065   # 255*63, libfdisk's default; re-read from the real label when --go
if has label && [ "$GO" = 1 ]; then
	run wipefs -a "$DISK"
	run dd if=/dev/zero of="$DISK" bs=1M count=4 conv=fsync status=none
	printf 'label: sun\n' | sfdisk --no-reread --no-tell-kernel "$DISK" >/dev/null
	g=$(fdisk -l "$DISK" | sed -n 's/^Geometry: \([0-9]*\) heads, \([0-9]*\) sectors\/track.*/\1 \2/p')
	[ -n "$g" ] && cyl=$(( ${g% *} * ${g#* } ))
fi
total=$(( bytes / 512 )); ncyl=$(( total / cyl ))
bootc=$(( BOOT_MIB * 2048 / cyl + 1 )); swapc=$(( SWAP_MIB * 2048 / cyl + 1 ))
# Align the root slice to 4 KiB (SSD pages): a cylinder is 16065 sectors (odd), so only a start that is a multiple of 8 cylinders
# is a multiple of 8 sectors. The swap slice absorbs the difference (at most 7 cylinders, about 56 MiB).
swapc=$(( (bootc + swapc + 7) / 8 * 8 - bootc ))
# The boot slice MUST start at sector 0 (cylinder 0): for Sun labels grub-sparc64-setup stores absolute disk sectors in the boot
# block (it only converts to partition-relative for GPT), while OpenBoot reads relative to the slice. They agree only if the
# slice starts at 0.
s1=0; s2=$(( s1 + bootc )); s4=$(( s2 + swapc ))
if [ "$AB" = 1 ]; then
	# A/B mode: split remaining space evenly between root-a (slice 4) and root-b (slice 5)
	remaining=$(( ncyl - s4 ))
	rootac=$(( remaining / 2 ))
	s5=$(( s4 + rootac ))
	echo "cylinder=$cyl sectors, $ncyl cylinders; slices start at cyl: boot=$s1 swap=$s2 root-a=$s4 root-b=$s5"
else
	echo "cylinder=$cyl sectors, $ncyl cylinders; slices start at cyl: boot=$s1 swap=$s2 root=$s4"
fi

# ---- phase: label ----------------------------------------------------------------------------
if has label; then
	echo "== label"
	if [ "$AB" = 1 ]; then
		script=$(printf 'label: sun\n1 : start=%d, size=%d, type=83\n2 : start=%d, size=%d, type=82\n3 : start=0, size=%d, type=5\n4 : start=%d, size=%d, type=83\n5 : start=%d, size=%d, type=83\n' \
			$((s1*cyl)) $((bootc*cyl)) $((s2*cyl)) $((swapc*cyl)) $((ncyl*cyl)) $((s4*cyl)) $((rootac*cyl)) $((s5*cyl)) $(((ncyl-s5)*cyl)))
	else
		script=$(printf 'label: sun\n1 : start=%d, size=%d, type=83\n2 : start=%d, size=%d, type=82\n3 : start=0, size=%d, type=5\n4 : start=%d, size=%d, type=83\n' \
			$((s1*cyl)) $((bootc*cyl)) $((s2*cyl)) $((swapc*cyl)) $((ncyl*cyl)) $((s4*cyl)) $(((ncyl-s4)*cyl)))
	fi
	printf '%s\n' "$script"
	if [ "$GO" = 1 ]; then printf '%s\n' "$script" | sfdisk "$DISK"; udevadm settle; partprobe "$DISK" || true; sleep 1; fi
	[ "$GO" = 0 ] || fdisk -l "$DISK"
fi

# ---- phase: mkfs -----------------------------------------------------------------------------
if has mkfs; then
	echo "== mkfs"
	# slice 1 starts at sector 0, so mke2fs would zero the Sun label (sectors 0-1): save it and put it back. Both through the SAME
	# device mke2fs writes through (the slice, not the whole disk): /dev/sdX and /dev/sdX1 cover the same sectors but have separate
	# page caches, and a buffered write of sector 0 through /dev/sdX writes back the whole 4 KiB page, a stale copy that can
	# overwrite the ext2 superblock (sector 2) mke2fs just wrote. (O_DIRECT would avoid it but some disks reject it.)
	lbl=$(mktemp); trap 'rm -f "$lbl"' EXIT
	run dd if="$(pdev 1)" of="$lbl" bs=512 count=1 status=none
	run mke2fs -F -q -t ext2 -L boot "$(pdev 1)"
	run dd if="$lbl" of="$(pdev 1)" bs=512 count=1 conv=notrunc,fsync status=none
	if [ "$GO" = 1 ]; then
		blockdev --flushbufs "$DISK"      # drop cached copies so the checks below read what is really on the disk
		fdisk -l "$DISK" | grep -q "Disklabel type: sun" || { echo "Sun label lost after mke2fs!" >&2; exit 1; }
		dumpe2fs -h "$(pdev 1)" >/dev/null 2>&1 || { echo "the boot filesystem on $(pdev 1) is not valid after restoring the label" >&2; exit 1; }
	fi
	# sparc64 uses 8 KB pages and the kernel looks for the swap signature at PAGE_SIZE-10; mkswap on an x86 PC defaults to 4 KB
	# pages and writes it at byte 4086, so the Ultra 10 would report "Unable to find swap-space signature". Force 8192.
	run mkswap -p 8192 -L swap "$(pdev 2)"
	# shellcheck disable=SC2086
	run mkfs.ext4 -F -q -L rootfs-a $ROOT_MKFS_OPTS "$(pdev 4)"
	if [ "$AB" = 1 ]; then
		# shellcheck disable=SC2086
		run mkfs.ext4 -F -q -L rootfs-b $ROOT_MKFS_OPTS "$(pdev 5)"
	fi
fi

# ---- phases that need the filesystems mounted -------------------------------------------------
if has copy || has boot; then
	cleanup() {
		set +e
		mountpoint -q "$MNT/boot" && umount "$MNT/boot"
		mountpoint -q "$MNT" && umount "$MNT"
		if [ "$AB" = 1 ]; then
			mountpoint -q "$MNT-b" && umount "$MNT-b"
		fi
		return 0
	}
	trap cleanup EXIT
	run mkdir -p "$MNT"
	run mount "$(pdev 4)" "$MNT"
	run mkdir -p "$MNT/boot"
	run mount "$(pdev 1)" "$MNT/boot"
	if [ "$AB" = 1 ] && has copy; then
		run mkdir -p "$MNT-b"
		run mount "$(pdev 5)" "$MNT-b"
	fi
fi

# ---- phase: copy: the root filesystem, the kernel, the fstab ---------------------------------------
if has copy; then
	echo "== unpack the root filesystem: $TAR"
	run tar -C "$MNT" -xpf "$TAR" --numeric-owner --xattrs --xattrs-include='*.*' --acls
	
	if [ "$AB" = 1 ]; then
		echo "== also unpack to rootfs-b for A/B setup"
		run tar -C "$MNT-b" -xpf "$TAR" --numeric-owner --xattrs --xattrs-include='*.*' --acls
	fi

	KVER=$(cat "$KDIR/release")
	echo "== install kernel $KVER"
	run cp "$KDIR/vmlinux" "$MNT/boot/vmlinux-$KVER"
	run cp "$KDIR/config" "$MNT/boot/config-$KVER"
	run cp "$KDIR/System.map" "$MNT/boot/System.map-$KVER"
	run mkdir -p "$MNT/usr/lib/modules"
	run bash -c "tar -C '$KDIR/modules/lib/modules' --owner=0 --group=0 --numeric-owner -cf - '$KVER' | tar -C '$MNT/usr/lib/modules' --numeric-owner -xpf -"

	# fstab for this layout, by label so device names do not matter (this script owns the labels)
	echo "== write $MNT/etc/fstab"
	if [ "$GO" = 1 ]; then
		if [ "$AB" = 1 ]; then
			cat >"$MNT/etc/fstab" <<-EOF
			LABEL=rootfs-a	/	ext4	errors=remount-ro	0	1
			LABEL=boot	/boot	ext2	defaults,nofail	0	2
			LABEL=swap	none	swap	sw,nofail	0	0
			tracefs	/sys/kernel/tracing	tracefs	defaults,nofail	0	0
			EOF
			cat >"$MNT-b/etc/fstab" <<-EOF
			LABEL=rootfs-b	/	ext4	errors=remount-ro	0	1
			LABEL=boot	/boot	ext2	defaults,nofail	0	2
			LABEL=swap	none	swap	sw,nofail	0	0
			tracefs	/sys/kernel/tracing	tracefs	defaults,nofail	0	0
			EOF
		else
			cat >"$MNT/etc/fstab" <<-EOF
			LABEL=rootfs	/	ext4	errors=remount-ro	0	1
			LABEL=boot	/boot	ext2	defaults,nofail	0	2
			LABEL=swap	none	swap	sw,nofail	0	0
			tracefs	/sys/kernel/tracing	tracefs	defaults,nofail	0	0
			EOF
		fi
	fi
	echo "== install /root/bench.sh (sh bench.sh prints memory/disk/kernel numbers)"
	[ "$GO" = 0 ] || install -D -m 755 "$ROOT/tools/guest/bench.sh" "$MNT/root/bench.sh"
fi

# ---- phase: boot (GRUB) ----------------------------------------------------------------------
if has boot; then
	echo "== GRUB sparc64-ieee1275"
	MOD=$GRUB/lib/grub/sparc64-ieee1275
	[ -d "$MOD" ] || { echo "GRUB not built: run tools/build-grub.sh" >&2; exit 1; }
	pd=$MNT/boot/grub/sparc64-ieee1275
	run mkdir -p "$pd"
	run bash -c "cp '$MOD'/*.mod '$MOD'/*.lst '$MOD'/boot.img '$pd'/"
	# the prefix has no device: at run time GRUB takes the root device from the OpenBoot boot path
	run "$GRUB/bin/grub-mkimage" -d "$MOD" -O sparc64-ieee1275-raw -p /grub -o "$pd/core.img" \
		ext2 part_sun part_gpt part_msdos normal linux ls cat echo configfile
	# one menu entry per kernel in /boot (plus a rescue entry each)
	gdef=""; [ -z "$GRUBDEF" ] || gdef="--default '$GRUBDEF'"
	[ "$DMATESTS" = 0 ] || gdef="$gdef --dma-tests"
	[ "$AB" = 0 ] || gdef="$gdef --ab"
	run bash -c "'$ROOT/tools/make-grub-cfg.sh' '$MNT/boot' --kargs '$KARGS' $gdef > '$MNT/boot/grub/grub.cfg'"
	[ "$GO" = 0 ] || : >"$pd/device.map"
	run "$GRUB/sbin/grub-sparc64-setup" -v -f -s -d "$pd" -m "$pd/device.map" "$(pdev 1)"
	[ "$GO" = 0 ] || { echo; cat "$MNT/boot/grub/grub.cfg"; ls -l "$MNT/boot"; }
fi

[ "$GO" = 0 ] || sync
echo
echo "done. On the Ultra 10, at the OpenBoot 'ok' prompt:  boot disk"
echo "(verify the boot block first with:  sudo tools/check-boot.sh ${DISK}1)"
