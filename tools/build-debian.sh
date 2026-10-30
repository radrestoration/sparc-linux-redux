#!/usr/bin/env bash
# Build the Ultra 10's Debian root filesystem (Debian "sid" for sparc64, sysvinit, no systemd) on this PC, as one tarball that
# tools/prepare-disk.sh installs onto the disk.
#
#   tools/build-debian.sh [--config FILE] [--out FILE] [--with-x | --with-cde [--cde-debs DIR]] [--hostname NAME] [--iface IF] [--addr CIDR] [--gateway IP] [--dns "IP ..."]
#                              [--root-password PW] [--user NAME] [--user-password PW] [--proxy URL]
#
# Run it as your normal user (no sudo): it re-runs itself in a user namespace (unshare --map-auto --map-root-user), where it is
# "root" with a private range of uids from /etc/subuid, enough for the packages' chown/useradd and the foreign chroot. Under sudo it
# works as before. Nothing but the tarball is ever written as the real root.
#
# one-time setup:  sudo apt install debootstrap debian-ports-archive-keyring qemu-user qemu-user-binfmt
#
# How it works: debootstrap downloads and unpacks the packages (--foreign), the package configuration scripts then run in a chroot
# through qemu-user (sparc64 on this PC), the system is configured, and everything is packed. All work happens under /var/tmp, so nothing
# lands in the project but the tarball. Files left in the work directory by a failed rootless run belong to subuids: re-running the
# script cleans them up (inside the namespace); plain rm cannot.
#
# --out            result (default: build/debian/rootfs.tar)
# --config         settings file (default: config/ultra10-baseline.conf: hostname, interface, address, gateway, DNS, apt proxy, root password, packages).
#                  Give it FIRST: the other options override it.
# --with-x         append X packages from config/ultra10-with-x.conf (Xorg, xterm, X applications; no window manager or display manager)
# --with-cde       --with-x plus the Common Desktop Environment (build/cde/deb, made by cde/package.sh; see cde/): dtlogin is the display manager
# --hostname/--iface/--addr/--gateway/--dns/--root-password/--user/--user-password/--proxy   override the files for one build
#
# Settings are read from config/defaults.conf, then the package list (--config, default ultra10-baseline.conf), then config/local.conf (yours,
# git-ignored: passwords, address, USER_NAME ...). USER_NAME creates an ordinary user with the same X session as root.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/debian/rootfs.tar
WORK=/var/tmp/ultra10-debian${ULTRA10_REAL_USER:+-$ULTRA10_REAL_USER}      # rootless runs get their own directory
MIRROR=http://deb.debian.org/debian-ports
SUITE=sid
KEYRING=/usr/share/keyrings/debian-ports-archive-keyring.gpg
CONFIG=$ROOT/config/ultra10-baseline.conf
SETTINGS=$ROOT/config/defaults.conf      # machine settings
LOCAL=$ROOT/config/local.conf           # optional personal overrides (git-ignored)
HOSTNAME_=ultra10 IFACE=eth0 ADDR=192.168.2.20/24 GATEWAY= DNS= ROOTPW=root PROXY= PACKAGES= USERNAME= USERPW= USERGROUPS="sudo audio video input plugdev users" USERKEY=      # used if the config file is missing
WITH_X=0
WITH_CDE=0 CDE_DEBS=$ROOT/build/cde/deb      # --with-cde: the Common Desktop Environment packages from cde/package.sh
REFUSE="init systemd-sysv systemd"       # none of these may end up in the image

say() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

preflight() {
	[ "$(id -u)" = 0 ] || die "not root, and not in a user namespace"
	for t in debootstrap python3 openssl dpkg-deb tar; do command -v "$t" >/dev/null || die "missing tool: $t (see the setup line at the top of this script)"; done
	[ -f "$KEYRING" ] || die "$KEYRING missing: sudo apt install debian-ports-archive-keyring"
	local b=/proc/sys/fs/binfmt_misc/qemu-sparc64
	[ -r "$b" ] || die "qemu-sparc64 is not registered: sudo apt install qemu-user qemu-user-binfmt  (check: cat $b)"
	grep -q '^enabled' "$b" || die "qemu-sparc64 is registered but not enabled: $b"
	grep -q '^flags:.*F' "$b" || die "qemu-sparc64 lacks the F flag, so the chroot would need the emulator copied in: $b"
	case $WORK in /var/tmp/?*) ;; *) die "refusing WORK='$WORK'";; esac
	# speed: if an apt-cacher-ng answers on this PC, downloads go through it
	BUILD_PROXY=; (echo >/dev/tcp/127.0.0.1/3142) 2>/dev/null && BUILD_PROXY=http://127.0.0.1:3142 || true
}

# ---- 1. the package list: apt's own resolver, run against the ports index in a private directory ---------------------------------
# read KEY=value lines (not sourced: this runs as root); unknown keys are an error so a typo is not silently ignored
load_config() {
	local k v
	[ -r "$1" ] || die "cannot read the config file: $1"
	while IFS='=' read -r k v; do
		case $k in ''|'#'*) continue;; esac
		case $k in
		HOSTNAME) HOSTNAME_=$v;; IFACE) IFACE=$v;; ADDRESS) ADDR=$v;; GATEWAY) GATEWAY=$v;; DNS) DNS=$v;;
		APT_PROXY) PROXY=$v;; ROOT_PASSWORD) ROOTPW=$v;; USER_NAME) USERNAME=$v;; USER_PASSWORD) USERPW=$v;; USER_GROUPS) USERGROUPS=$v;; USER_SSH_KEY_FILE) USERKEY=$v;; PACKAGES) PACKAGES=$v;;
		*) die "$1: unknown setting '$k'";;
		esac
	done <"$1"
}

resolve_packages() {
	say "1/6 resolving the package list"
	local A=$WORK/aptroot
	mkdir -p "$A"/etc/apt/apt.conf.d "$A"/etc/apt/preferences.d "$A"/etc/apt/trusted.gpg.d "$A"/var/lib/apt/lists/partial "$A"/var/cache/apt/archives/partial "$A"/var/lib/dpkg
	: >"$A/var/lib/dpkg/status"
	echo "deb [arch=sparc64 signed-by=$KEYRING] $MIRROR $SUITE main" >"$A/etc/apt/sources.list"
	cat >"$A/apt.conf" <<-EOF
	Dir "$A"; Dir::State "$A/var/lib/apt"; Dir::State::status "$A/var/lib/dpkg/status"; Dir::Cache "$A/var/cache/apt"; Dir::Etc "$A/etc/apt";
	APT::Architecture "sparc64"; APT::Architectures "sparc64"; Debug::NoLocking "1"; APT::Install-Recommends "0";
	EOF
	[ -z "$BUILD_PROXY" ] || echo "Acquire::http::Proxy \"$BUILD_PROXY\";" >>"$A/apt.conf"
	export APT_CONFIG=$A/apt.conf LC_ALL=C
	apt-get update >/dev/null
	local required seed
	required=$(apt-cache dumpavail | awk 'BEGIN{RS="";FS="\n"} /\nPriority: required/ {for(i=1;i<=NF;i++) if($i ~ /^Package: /){sub("Package: ","",$i); print $i}}')
	seed=$(printf '%s\n' $required $PACKAGES | grep -vxE "$(echo $REFUSE | tr ' ' '|')" | sort -u | tr '\n' ' ')
	apt-get -s install $seed >"$WORK/resolve.out" 2>&1 || { grep '^E:' "$WORK/resolve.out" >&2; die "apt could not resolve the package set"; }
	grep '^Inst' "$WORK/resolve.out" | awk '{print $2}' | sort -u >"$WORK/packages.list"
	for bad in $REFUSE; do grep -qx "$bad" "$WORK/packages.list" && die "'$bad' is in the resolved list: something depends on it alone"; done
	echo "$(wc -l <"$WORK/packages.list") packages"
	unset APT_CONFIG
}

# ---- 2. debootstrap stage 1: download and unpack ------------------------------------------------------------------------------
bootstrap() {
	say "2/6 debootstrap (download and unpack)"
	# --no-resolve-deps because debootstrap's resolver would add systemd back (--exclude only trims its starting lists)
	http_proxy=$BUILD_PROXY debootstrap --foreign --arch=sparc64 --variant=minbase --keyring="$KEYRING" \
		--no-resolve-deps --include="$(paste -sd, "$WORK/packages.list")" --exclude="${REFUSE// /,}" "$SUITE" "$CH" "$MIRROR"
	# stage 1 unpacks only the "required" packages and counts on the resolver for their libraries, which we switched off: unpack the
	# files of every downloaded package now, so the chroot has libc and a shell. (dpkg --unpack in stage 2 overwrites them.)
	for d in "$CH"/var/cache/apt/archives/*.deb; do dpkg-deb --fsys-tarfile "$d" | tar --keep-directory-symlink -xf - -C "$CH"; done
	[ -e "$CH/usr/lib64/ld-linux.so.2" ] || die "the dynamic loader is missing from $CH"
}

# ---- 3. keep only the wanted packages in the index: stage 2 greps the whole index once per package, and under emulation the
# full 90 MB sparc64 index costs ~20 s per package (an hour in all). The finished image does not keep the index. -----------------
trim_index() {
	say "3/6 trimming the package index"
	local f
	for f in "$CH"/var/lib/apt/lists/*_Packages; do
		[ -f "$f" ] || continue
		python3 -I - "$WORK/packages.list" "$f" <<'PY'
import sys
want = set(open(sys.argv[1]).read().split())
src = sys.argv[2]
keep, total = [], 0
for st in open(src, encoding="utf-8", errors="surrogateescape").read().split("\n\n"):
    if st.strip():
        total += 1
        name = next((l[9:].strip() for l in st.split("\n") if l.startswith("Package:")), None)
        if name in want:
            keep.append((name, st.rstrip("\n")))
missing = sorted(want - {n for n, _ in keep})
if missing:
    sys.exit("no stanza in the index for: " + " ".join(missing))
open(src, "w", encoding="utf-8", errors="surrogateescape").write("\n\n".join(s for _, s in keep) + "\n\n")
print(f"index trimmed: {len(keep)} of {total} stanzas")
PY
	done
}

# ---- 4. debootstrap stage 2: the configure scripts, in a chroot through qemu-user ---------------------------------------------
unmount_chroot() {
	local m
	for m in dev sys proc; do
		if mountpoint -q "$CH/$m" 2>/dev/null; then umount -R "$CH/$m" 2>/dev/null || umount -l "$CH/$m" || true; fi
	done
	return 0
}

second_stage() {
	say "4/6 package configuration (debootstrap --second-stage under qemu-user)"
	# policy-rc.d exit 101: packages must not start services (an sshd, say) while they are configured in the chroot
	printf '#!/bin/sh\nexit 101\n' >"$CH/usr/sbin/policy-rc.d"; chmod 755 "$CH/usr/sbin/policy-rc.d"
	mkdir -p "$CH/etc/dpkg/dpkg.cfg.d"
	# no docs/man pages/translations on a 128 MB machine; and no per-file fsync (dpkg flushes every file, which is crawl-slow on this
	# PIO disk; left in the image so apt stays usable there; delete 02_unsafe_io for the safe behaviour)
	cat >"$CH/etc/dpkg/dpkg.cfg.d/01_lean" <<-'EOF'
	path-exclude=/usr/share/doc/*
	path-include=/usr/share/doc/*/copyright
	path-exclude=/usr/share/man/*
	path-exclude=/usr/share/info/*
	path-exclude=/usr/share/locale/*
	path-include=/usr/share/locale/locale.alias
	path-exclude=/usr/share/lintian/*
	path-exclude=/usr/lib/udev/hwdb.d/*
	EOF
	printf 'force-unsafe-io\n' >"$CH/etc/dpkg/dpkg.cfg.d/02_unsafe_io"
	mkdir -p "$CH/proc" "$CH/sys" "$CH/dev"
	mount -t proc proc "$CH/proc"
	mount -t sysfs sysfs "$CH/sys" 2>/dev/null || echo "note: /sys not mounted in the chroot (not allowed in a user namespace)"
	mount --rbind /dev "$CH/dev"; mount --make-rslave "$CH/dev"        # rslave: host changes show up, nothing propagates back
	# an explicit Debian-style PATH: debootstrap checks for chroot in /usr/sbin, which the calling shell's PATH may not have
	chroot "$CH" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb LC_ALL=C DEBIAN_FRONTEND=noninteractive \
		/debootstrap/debootstrap --second-stage
	unmount_chroot
	rm -f "$CH/usr/sbin/policy-rc.d"
}

# ---- 4b. CDE (--with-cde): the .deb files from cde/package.sh; their library dependencies join the package list, they are installed with
# dpkg in the chroot once stage 2 is done, and dtlogin is the display manager as the display manager ------------------------------------------
cde_plan() {
	local d deps
	for d in cde-desktop cde-help; do ls "$CDE_DEBS/${d}_"*_sparc64.deb >/dev/null 2>&1 || die "no $d package in $CDE_DEBS (run cde/package.sh, or --cde-debs DIR)"; done
	deps=$(for d in "$CDE_DEBS"/*.deb; do dpkg-deb -f "$d" Depends; done | tr ',' '\n' | sed 's/(.*//; s/|.*//; s/ //g' | grep -v '^$' | grep -v '^cde-' | sort -u | tr '\n' ' ')
	PACKAGES="$(printf '%s\n' $PACKAGES $deps | sort -u | tr '\n' ' ')"
	echo "CDE: ${deps}"
}

install_cde() {
	say "4b/6 installing CDE"
	mkdir -p "$CH/tmp/cde"; cp "$CDE_DEBS"/*.deb "$CH/tmp/cde/"
	chroot "$CH" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb LC_ALL=C DEBIAN_FRONTEND=noninteractive \
		sh -c 'dpkg -i /tmp/cde/*.deb && update-rc.d dtlogin defaults'
	rm -rf "$CH/tmp/cde"
	[ -x "$CH/usr/dt/bin/dtlogin" ] || die "CDE did not install"
	ls "$CH"/etc/rc2.d/*dtlogin >/dev/null || die "dtlogin was not enabled"
}

# ---- 5. configuration (nothing in it is executed) ------------------------------------------------------------------------------
configure() {
	say "5/6 configuring the system"
	echo "$HOSTNAME_" >"$CH/etc/hostname"
	if [ "$WITH_X" = 1 ]; then
		# ATY Mach64 (Rage IIc, 4 MB VRAM) via fbdev: 1600x900 at 16 bit needs 2.9 MB (24-bit colour does not fit); the ati driver was not needed
		mkdir -p "$CH/etc/X11/xorg.conf.d"
		cat >"$CH/etc/X11/xorg.conf.d/20-fbdev.conf" <<-'EOF'
		Section "Monitor"
		    Identifier "m0"
		    Modeline "1600x900" 118.25 1600 1688 1856 2112 900 903 908 934 -hsync +vsync
		EndSection
		Section "Device"
		    Identifier "fb"
		    Driver "fbdev"
		    Option "fbdev" "/dev/fb0"
		EndSection
		Section "Screen"
		    Identifier "s0"
		    Device "fb"
		    Monitor "m0"
		    DefaultDepth 16
		    SubSection "Display"
		        Depth 16
		        Modes "1600x900"
		    EndSubSection
		EndSection
		EOF
	fi
	if [ -n "$USERNAME" ]; then
		[[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "USER_NAME '$USERNAME' is not a valid login name"
		[ -n "$USERPW" ] || die "USER_NAME is set but USER_PASSWORD is empty"
		[ "$USERNAME" != root ] || die "USER_NAME must not be root"
		local uhash H ugid; uhash=$(openssl passwd -6 "$USERPW")
		python3 -I - "$CH" "$USERNAME" "$uhash" "$USERGROUPS" <<'PYU'
import sys
ch, name, h, groups = sys.argv[1:5]
def rd(n): return open(ch + n).read().rstrip("\n").split("\n")
def wr(n, l): open(ch + n, "w").write("\n".join(l) + "\n")
pw, gr = rd("/etc/passwd"), rd("/etc/group")
assert not any(l.split(":")[0] == name for l in pw), "user exists"
used = {int(l.split(":")[2]) for l in gr}
gid = 1000
while gid in used: gid += 1
gr = [l + ("," if l.split(":")[3] else "") + name if l.split(":")[0] in groups.split() else l for l in gr]
gr.append("%s:x:%d:" % (name, gid))
pw.append("%s:x:1000:%d:%s:/home/%s:/bin/bash" % (name, gid, name, name))
wr("/etc/passwd", pw); wr("/etc/group", gr)
sh = rd("/etc/shadow"); sh.append("%s:%s:20000:0:99999:7:::" % (name, h)); wr("/etc/shadow", sh)
sg = rd("/etc/gshadow"); sg.append("%s:!::" % name); wr("/etc/gshadow", sg)
PYU
		H=$CH/home/$USERNAME
		ugid=$(grep "^$USERNAME:" "$CH/etc/group" | cut -d: -f3)
		mkdir -p "$H"; cp -a "$CH"/etc/skel/. "$H"/
		if [ -n "$USERKEY" ]; then
			[ -r "$USERKEY" ] || die "USER_SSH_KEY_FILE not readable: $USERKEY"
			mkdir -p "$H/.ssh"; cp "$USERKEY" "$H/.ssh/authorized_keys"; chmod 700 "$H/.ssh"; chmod 600 "$H/.ssh/authorized_keys"
		fi
		chown -R "1000:$ugid" "$H"; chmod 755 "$H"
	fi
	printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME_" >"$CH/etc/hosts"
	mkdir -p "$CH/etc/network"
	cat >"$CH/etc/network/interfaces" <<-EOF
	auto lo
	iface lo inet loopback

	auto $IFACE
	iface $IFACE inet static
	    address $ADDR
	EOF
	[ -z "$GATEWAY" ] || printf '    gateway %s\n' "$GATEWAY" >>"$CH/etc/network/interfaces"
	[ -z "$DNS" ] || { local ns; for ns in $DNS; do printf 'nameserver %s\n' "$ns"; done >"$CH/etc/resolv.conf"; }
	# keep the kernel's names (eth0, eth1) instead of udev's "predictable" ones (enp1s1f1): an empty /etc link file overrides
	# the default naming policy in /usr/lib/systemd/network/99-default.link
	mkdir -p "$CH/etc/systemd/network"; ln -sf /dev/null "$CH/etc/systemd/network/99-default.link"
	echo "deb [signed-by=$KEYRING] $MIRROR $SUITE main" >"$CH/etc/apt/sources.list"
	printf 'APT::Install-Recommends "0";\nAPT::Install-Suggests "0";\n' >"$CH/etc/apt/apt.conf.d/02lean"
	[ -z "$PROXY" ] || printf 'Acquire::http::Proxy "%s";\n' "$PROXY" >"$CH/etc/apt/apt.conf.d/01proxy"
	mkdir -p "$CH/etc/ssh/sshd_config.d"; printf 'PermitRootLogin yes\n' >"$CH/etc/ssh/sshd_config.d/10-root-login.conf"
	# a reboot from Linux calls OpenBoot "boot <kernel.reboot-cmd>"; empty means the NVRAM boot-device, which is "net" first
	# (and forgotten at power-off if the NVRAM battery is dead), so name the disk explicitly
	mkdir -p "$CH/etc/sysctl.d"; printf 'kernel.reboot-cmd = disk\n' >"$CH/etc/sysctl.d/10-sparc-reboot.conf"
	# no initramfs: USB keyboard/mouse support is modular, so load it at boot (evdev gives /dev/input/event*)
	printf 'ohci_pci\nusbhid\nhid_generic\nevdev\n' >>"$CH/etc/modules"
	# two virtual-console gettys are plenty for a machine used over ssh (each costs memory on a 128 MB machine)
	sed -i 's/^\([3-6]:[0-9]*:respawn:\/sbin\/getty\)/#\1/' "$CH/etc/inittab"
	[ "$(grep -c '^[1-6]:[0-9]*:respawn:/sbin/getty' "$CH/etc/inittab")" = 2 ] || die "unexpected /etc/inittab: could not reduce the gettys to two"
	local hash; hash=$(openssl passwd -6 "$ROOTPW")
	python3 -I - "$CH/etc/shadow" "$hash" <<'PY'
import sys
p, h = sys.argv[1], sys.argv[2]
lines = open(p).read().split("\n")
for i, l in enumerate(lines):
    f = l.split(":")
    if f[0] == "root" and len(f) > 2:
        f[1] = h
        lines[i] = ":".join(f)
open(p, "w").write("\n".join(lines))
PY
	# (/etc/fstab is written by prepare-disk.sh, which owns the partition labels)
}

# the 01_lean dpkg excludes only affect files dpkg unpacks itself; stage 1 unpacked everything, so remove the same things here
# (documentation, man/info pages, translations, the udev hardware-database sources: about 55 MB, none of it needed on a console box)
prune() {
	find "$CH/usr/share/doc" -mindepth 2 \( -type f -o -type l \) ! -name copyright -delete
	find "$CH/usr/share/doc" -mindepth 2 -type d -empty -delete
	find "$CH/usr/share/man" "$CH/usr/share/info" "$CH/usr/share/lintian" "$CH/usr/lib/udev/hwdb.d" -mindepth 1 -delete 2>/dev/null || true
	find "$CH/usr/share/locale" -mindepth 1 ! -name locale.alias -delete
	rm -f "$CH"/var/cache/debconf/*-old "$CH"/var/lib/dpkg/*-old
}

# ---- 6. checks, tidy-up, pack ---------------------------------------------------------------------------------------------------
finish() {
	say "6/6 checking and packing"
	# the image must not contain systemd or lack its setuid/setgid programs
	local bad
	for bad in $REFUSE; do
		awk -v p="$bad" '/^Package: /{n=$2} /^Status: .* installed/{if(n==p) f=1} END{exit !f}' "$CH/var/lib/dpkg/status" && die "'$bad' ended up installed"
	done
	find "$CH/var/lib/apt/lists" "$CH/var/cache/apt/archives" -type f -delete 2>/dev/null || true
	prune
	# sparc64 binaries carry ~1 MiB of zero padding each: turn it into holes (smaller image, less I/O on the slow disk). NEVER on
	# setuid/setgid files: punching a hole is a write, and the kernel clears those bits on any write (hence ! -perm /6000).
	find "$CH" -xdev -type f -size +64k ! -perm /6000 -exec fallocate --dig-holes {} \; 2>/dev/null || true
	local f
	for f in usr/bin/su usr/bin/passwd usr/bin/mount; do [ -u "$CH/$f" ] || die "$f lost its setuid bit"; done
	[ -g "$CH/usr/sbin/unix_chkpwd" ] || die "unix_chkpwd lost its setgid bit"
	mkdir -p "$(dirname "$OUT")"
	tar --sparse --numeric-owner --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' -cpf "$OUT" -C "$CH" .
	[ -z "${SUDO_USER:-}" ] || chown "$SUDO_USER" "$OUT"
	ls -l "$OUT"
}

cleanup_work() {
	unmount_chroot
	grep -q " $WORK" /proc/mounts && die "something is still mounted under $WORK; not removing it"
	rm -rf --one-file-system "$WORK"
}

main() {
	# not root: become "root" in a user namespace (maps 0 -> this user, 1.. -> the /etc/subuid range) and run again
	if [ "$(id -u)" != 0 ]; then
		command -v unshare >/dev/null || die "unshare missing (util-linux)"
		grep -q "^$(id -un):" /etc/subuid || die "no /etc/subuid range for $(id -un): sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)"
		unshare --map-auto --map-root-user --mount true 2>/dev/null || die "cannot create a user namespace (on Ubuntu 24.04+ AppArmor blocks it: kernel.apparmor_restrict_unprivileged_userns=1). Either run this script with sudo, or allow /usr/bin/unshare with an AppArmor 'userns,' profile (see /etc/apparmor.d/lxc-unshare for the pattern)"
		ULTRA10_REAL_USER=$(id -un) exec unshare --map-auto --map-root-user --mount --pid --fork "$0" "$@"
	fi
	[ ! -r "$SETTINGS" ] || load_config "$SETTINGS"
	[ ! -r "$CONFIG" ] || load_config "$CONFIG"
	[ ! -r "$LOCAL" ] || load_config "$LOCAL"
	while [ $# -gt 0 ]; do
		case $1 in
		--config) load_config "$2"; shift 2;;
		--with-x) load_config "$ROOT/config/ultra10-with-x.conf"; WITH_X=1; shift 1;;
		--with-cde) load_config "$ROOT/config/ultra10-with-x.conf"; WITH_X=1; WITH_CDE=1; shift 1;;
		--cde-debs) CDE_DEBS=$2; shift 2;;
		--gateway) GATEWAY=$2; shift 2;;
		--dns) DNS=$2; shift 2;;
		--out) OUT=$2; shift 2;;
		--hostname) HOSTNAME_=$2; shift 2;;
		--iface) IFACE=$2; shift 2;;
		--addr) ADDR=$2; shift 2;;
		--root-password) ROOTPW=$2; shift 2;;
		--user) USERNAME=$2; shift 2;;
		--user-password) USERPW=$2; shift 2;;
		--proxy) PROXY=$2; shift 2;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0;;
		*) die "unknown option: $1";;
		esac
	done
	preflight
	[ "$WITH_CDE" = 0 ] || cde_plan
	CH=$WORK/root
	trap unmount_chroot EXIT
	[ ! -e "$WORK" ] || cleanup_work          # a previous (failed) run
	mkdir -p "$CH"
	resolve_packages
	bootstrap
	trim_index
	second_stage
	[ "$WITH_CDE" = 0 ] || install_cde
	configure
	finish
	cleanup_work
	say "done: $OUT"
	echo "install it:  sudo tools/prepare-disk.sh --disk /dev/sdX --rootfs-tar $OUT --kernel-dir build/kernel/out/7.3-ultra10 --go --confirm sdX"
}

# run main only when executed, not when sourced (so the steps can be tested one by one)
[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
