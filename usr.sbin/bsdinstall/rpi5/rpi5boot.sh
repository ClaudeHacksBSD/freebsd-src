#!/bin/sh
#-
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#
# rpi5boot -- on the Raspberry Pi 5 installer card, make the card boot the
# system that was just installed.
#
# The installer card (release/arm64/make-rpi5-memstick.sh) has
# /usr/libexec/bsdinstall/local.post-configure as a link to this file.
# bsdinstall's interactive installer ("auto") runs that file, if it
# exists, after the new system's /etc and /boot are final and before it
# unmounts the new system:
#
#	sh /usr/libexec/bsdinstall/local.post-configure "$BSDINSTALL_CHROOT"
#
# A scripted install (bsdinstall script) does not run hooks; call this from
# its own post-install section, from outside the chroot.
#
# THE CARD
#
#	s1   FAT                    the Pi 5 firmware's: config.txt, the device
#	                            trees, rpiboot.bin (the FreeBSD loader),
#	                            loader.env
#	s2a  UFS "freebsd-boot"     /boot: the kernel, its modules, loader.conf,
#	                            the loader's scripts.  loader.env names it
#	                            (rootdev=disk0s2a:), and the loader reads
#	                            the card itself
#	s3a  UFS "freebsd-install"  the installer's root, last on the card
#
# The installer mounts freebsd-boot at /boot, read-only, and boots the
# kernel on it with its own root.  So one kernel serves the installer and
# the installed system, and nothing on the FAT changes at install time.
#
# WHAT THIS DOES
#
#   1. Finds the new system's root: the "/" line of its /etc/fstab (UFS),
#      or the dataset mounted at the install root (ZFS).
#   2. Adds freebsd-boot to the new system's /etc/fstab, at /boot, so that
#      installkernel and everything else that writes /boot writes the card,
#      and the loader reads it at the next boot.  The original fstab is kept
#      as fstab.bsdinstall.
#   3. On freebsd-boot: copies the new system's zpool.cache, makes
#      /boot/entropy, and asks about the installer (below).
#   4. Last, replaces loader.conf on freebsd-boot: the board's settings
#      (loader.conf.rpi5), then the new system's own /boot/loader.conf, then
#      vfs.root.mountfrom for the new root.  This is the step that changes
#      what the card boots; everything before it leaves the installer
#      booting.
#
# THE INSTALLER, AFTERWARDS: the user chooses.
#
#   Keep      /boot/lua/local.lua adds "FreeBSD Installer" to the loader's
#             menu (key I): the same kernel, with freebsd-install as root.
#   Recycle   The partition cannot be deleted now, because the installer is
#             running from it.  A first-boot script in the new system
#             (rpi5_recycle) deletes it and, as chosen, grows freebsd-boot
#             into the installer's space, or to the end of the card, or not
#             at all.
#
# WHAT IT LEAVES ALONE
#
#   - The new system's own /boot directory, under the mount point: the
#     kernel.txz copy stays there, unused once /boot is mounted.
#   - A ZFS boot environment's name: bectl activate sets the pool's bootfs,
#     which this loader cannot read from a pool on NVMe or USB.  The name is
#     vfs.root.mountfrom in /boot/loader.conf, changed by hand.
#   - The kernel on the card.  It is the build kernel.txz on this card
#     installs.  If the new system's kernel is a different one (dist sets
#     from elsewhere), that is reported and the card's kernel is kept.
#
# For tests and for scripted installs:
#	RPI5BOOT_BOOTDIR=dir       where freebsd-boot is mounted (/boot)
#	RPI5BOOT_ROOT=fs:what      the new root, instead of step 1
#	RPI5BOOT_INSTALLER=keep|recycle-installer|recycle-card|recycle-none
#	                           the choice, without asking (and what is
#	                           done without a terminal: keep)
#	RPI5BOOT_LIBDIR=dir        where this hook's other files are
#	                           (/usr/libexec/bsdinstall)
#
# Log: /var/log/rpi5-bootconfig.log on the new system.

BOOTLABEL=freebsd-boot
INSTLABEL=freebsd-install

CHROOT=${1:-${BSDINSTALL_CHROOT:-/mnt}}
B=${RPI5BOOT_BOOTDIR:-/boot}
LIBDIR=${RPI5BOOT_LIBDIR:-/usr/libexec/bsdinstall}
OSNAME=${OSNAME:-FreeBSD}
TITLE="Raspberry Pi 5 boot"
LOG=$CHROOT/var/log/rpi5-bootconfig.log

say() {
	echo "rpi5boot: $*" >&2
	echo "$*" >>"$LOG" 2>/dev/null
}

have_ui() {
	[ -t 1 ] && command -v bsddialog >/dev/null 2>&1
}

# A box on the installer's screen, or plain text without a terminal.
ui() {	# infobox|msgbox text
	if have_ui; then
		bsddialog --backtitle "$OSNAME Installer" --title "$TITLE" \
		    "--$1" "$2" 0 0
	else
		printf '%b\n' "$2"
	fi
}

fail() {
	say "FAILED: $*"
	rm -f "$B/loader.conf.new"
	ui msgbox "This card still starts the installer, not the new system.\n\nReason: $*\n\nLog: /var/log/rpi5-bootconfig.log on the new system."
	exit 0
}

mkdir -p "$CHROOT/var/log" 2>/dev/null
: >"$LOG" 2>/dev/null
say "$(date -u '+%Y-%m-%d %H:%M:%S UTC') local.post-configure, new system at $CHROOT"

[ -d "$CHROOT/boot/kernel" ] || fail "no /boot/kernel in the new system at $CHROOT"
[ -f "$CHROOT/etc/fstab" ] || fail "the new system has no /etc/fstab"
for f in rpi5-installer-entry.lua rpi5-recycle.sh rpi5-recycle.rc; do
	[ -f "$LIBDIR/$f" ] || fail "$LIBDIR/$f is missing"
done

# The card's boot partition, where the installer has it mounted.
bootdev=$(mount -p | awk -v m="$B" '$2 == m { print $1; exit }')
[ -n "$bootdev" ] || fail "nothing is mounted at $B"
if [ -z "${RPI5BOOT_BOOTDIR-}" ] && [ "$bootdev" != "/dev/ufs/$BOOTLABEL" ]; then
	fail "$B is $bootdev, not the card's $BOOTLABEL partition"
fi
[ -f "$B/loader.conf.rpi5" ] || fail "$B has no loader.conf.rpi5; it is not this card's boot partition"
[ -f "$B/kernel/kernel" ] || fail "$B has no kernel"
say "boot:   $bootdev at $B"

# 1. The new system's root.
if [ -n "${RPI5BOOT_ROOT-}" ]; then
	mountfrom=$RPI5BOOT_ROOT
else
	mountfrom=$(awk '$1 !~ /^#/ && $2 == "/" { print $3 ":" $1; exit }' \
	    "$CHROOT/etc/fstab")
	if [ -z "$mountfrom" ]; then
		mountfrom=$(mount -p | awk -v m="$CHROOT" '$2 == m { print $3 ":" $1; exit }')
	fi
fi
case $mountfrom in
zfs:?*)		zfs=1 ;;
ufs:/dev/?*)	zfs=0 ;;
*)		fail "the new system's root (\"$mountfrom\") is neither UFS nor ZFS" ;;
esac
say "root:   $mountfrom"

if cmp -s "$CHROOT/boot/kernel/kernel" "$B/kernel/kernel"; then
	say "kernel: the new system's is the one on the card"
else
	say "kernel: the new system's /boot/kernel/kernel differs from the card's; the card's is kept"
	kernel_note="\n\nNote: the kernel that was installed is not the one on this card.  The card's kernel will be booted."
fi

# The installer: keep it, or recycle its partition at the first boot?
choice=${RPI5BOOT_INSTALLER-}
if [ -z "$choice" ] && have_ui; then
	if bsddialog --backtitle "$OSNAME Installer" --title "$TITLE" \
	    --yes-label "Keep" --no-label "Recycle" --yesno \
"The new system will start from this card: its kernel and loader are on the card's $BOOTLABEL partition, which the new system mounts at /boot.\n\nThe installer is on the card too.  Keep it?\n\nKeep: the loader's menu gets a \"FreeBSD Installer\" entry.\n\nRecycle: the installer's partition is deleted when the new system first starts." 0 0; then
		choice=keep
	else
		# The box on the terminal, the answer (bsddialog's stderr) here;
		# this script's own stderr is the installer's log.
		exec 5>&1
		choice=$(bsddialog --backtitle "$OSNAME Installer" --title "$TITLE" \
		    --no-cancel --menu \
"The installer's partition will be deleted at the first start of the new system.  What should become of its space?" 0 0 0 \
		    installer "Grow /boot into the installer's space" \
		    card "Grow /boot to the end of the card" \
		    none "Leave the space unused" 2>&1 1>&5)
		exec 5>&-
		choice=recycle-${choice:-none}
	fi
fi
case ${choice:=keep} in
keep|recycle-installer|recycle-card|recycle-none) ;;
*)	fail "unknown choice for the installer: $choice" ;;
esac
say "installer: $choice"

ui infobox "Making this card start the new system\n($mountfrom) ..."

# The card's boot partition is mounted read-only in the installer.
if [ -z "${RPI5BOOT_BOOTDIR-}" ]; then
	mount -u -o rw,noatime "$B" >>"$LOG" 2>&1 || fail "cannot make $B writable"
fi
touch "$B/.rpi5-write-test" 2>/dev/null && rm -f "$B/.rpi5-write-test" ||
    fail "$B is not writable"

# 2. The new system mounts the card's boot partition at /boot.  The line
# goes after the root's, or first if the root is not in fstab (ZFS), and so
# before any /boot/efi line: fstab is mounted in order.
if ! awk '$1 !~ /^#/ && $2 == "/boot" { found = 1 } END { exit !found }' \
    "$CHROOT/etc/fstab"; then
	cp -p "$CHROOT/etc/fstab" "$CHROOT/etc/fstab.bsdinstall" ||
	    fail "cannot copy the new system's fstab"
	awk -v line="/dev/ufs/$BOOTLABEL	/boot		ufs	rw,noatime	2	2" '
		NR == FNR { if ($1 !~ /^#/ && $2 == "/") root = 1; next }
		root && !done && $1 !~ /^#/ && $2 == "/" { print; print line; done = 1; next }
		!root && !done && $1 !~ /^#/ && NF > 0 { print line; done = 1 }
		{ print }
		END { if (!done) print line }' \
	    "$CHROOT/etc/fstab.bsdinstall" "$CHROOT/etc/fstab.bsdinstall" \
	    >"$CHROOT/etc/fstab" || fail "cannot write the new system's fstab"
fi
cat >"$CHROOT/boot/README.rpi5" <<EOF
This directory is the mount point of the SD card's $BOOTLABEL partition
(/dev/ufs/$BOOTLABEL in /etc/fstab).  The Raspberry Pi 5 loader reads the
kernel, its modules and loader.conf from that partition, so what counts is
what is in /boot while it is mounted.  The files beside this one were put
here by the installer before the partition was mounted, and are not used.
EOF
{
	echo "--- the new system's /etc/fstab"
	cat "$CHROOT/etc/fstab"
} >>"$LOG"

# 3. On the boot partition.
if [ -f "$CHROOT/boot/zfs/zpool.cache" ]; then
	mkdir -p "$B/zfs"
	cp -p "$CHROOT/boot/zfs/zpool.cache" "$B/zfs/zpool.cache" ||
	    fail "cannot copy zpool.cache"
fi
mkdir -p "$B/efi"
umask 077
dd if=/dev/random of="$B/entropy" bs=4096 count=1 >>"$LOG" 2>&1 ||
    fail "cannot write $B/entropy"
umask 022

rm -f "$CHROOT/usr/local/etc/rc.d/rpi5_recycle" \
    "$CHROOT/usr/local/libexec/rpi5-recycle" \
    "$CHROOT/etc/rc.conf.d/rpi5_recycle"
case $choice in
keep)
	sed "s|@INSTALLER_ROOT@|ufs:/dev/ufs/$INSTLABEL|" \
	    "$LIBDIR/rpi5-installer-entry.lua" >"$B/lua/local.lua" ||
	    fail "cannot write $B/lua/local.lua"
	;;
recycle-*)
	rm -f "$B/lua/local.lua"
	mkdir -p "$CHROOT/usr/local/etc/rc.d" "$CHROOT/usr/local/libexec" \
	    "$CHROOT/etc/rc.conf.d"
	install -m 555 "$LIBDIR/rpi5-recycle.rc" \
	    "$CHROOT/usr/local/etc/rc.d/rpi5_recycle" &&
	    install -m 555 "$LIBDIR/rpi5-recycle.sh" \
	    "$CHROOT/usr/local/libexec/rpi5-recycle" ||
	    fail "cannot install the first-boot script in the new system"
	cat >"$CHROOT/etc/rc.conf.d/rpi5_recycle" <<EOF
# Written by the installer: delete the installer's partition on the SD card
# at the first boot (/usr/local/etc/rc.d/rpi5_recycle).  grow is installer,
# card or none.
rpi5_recycle_enable="YES"
rpi5_recycle_grow="${choice#recycle-}"
EOF
	# rc(8) runs "firstboot" scripts only while this file exists.
	touch "$CHROOT/firstboot" || fail "cannot create /firstboot in the new system"
	;;
esac

# 4. loader.conf, last: this is what changes the boot.
{
	echo "# loader.conf on the SD card's $BOOTLABEL partition, which is /boot."
	echo "# Written by the installer, $(date -u '+%Y-%m-%d'); edit it as on any system."
	echo "# The board's settings come first, so that later lines override them."
	echo
	grep -v -E '^[[:space:]]*(#|$)' "$B/loader.conf.rpi5"
	echo
	echo "# From the installed system's /boot/loader.conf:"
	if [ -f "$CHROOT/boot/loader.conf" ]; then
		grep -v -E '^[[:space:]]*(#|$)' "$CHROOT/boot/loader.conf" |
		    grep -v -E '^(kernel|vfs\.root\.mountfrom)='
	fi
	if [ $zfs -eq 1 ] && ! grep -q '^zfs_load="*[Yy]' "$CHROOT/boot/loader.conf" 2>/dev/null; then
		echo 'zfs_load="YES"'
	fi
	echo
	echo "# The root.  With ZFS this names the boot environment: the loader"
	echo "# cannot read the pool, so after bectl activate, change it here."
	echo 'kernel="kernel"'
	echo "vfs.root.mountfrom=\"$mountfrom\""
} >"$B/loader.conf.new" || fail "cannot write $B/loader.conf.new"
grep -q "^vfs.root.mountfrom=\"$mountfrom\"\$" "$B/loader.conf.new" ||
    fail "$B/loader.conf.new is incomplete"
[ -f "$B/loader.conf.installer" ] || cp -p "$B/loader.conf" "$B/loader.conf.installer"
mv "$B/loader.conf.new" "$B/loader.conf" || fail "cannot replace $B/loader.conf"
sync
{
	echo "--- $B/loader.conf"
	cat "$B/loader.conf"
} >>"$LOG"
say "done:   the card now boots $mountfrom"

case $choice in
keep)
	after="The installer stays on the card: choose \"FreeBSD Installer\" (key I) in the loader's menu." ;;
recycle-none)
	after="The installer's partition will be deleted when the new system first starts." ;;
*)
	after="When the new system first starts, the installer's partition will be deleted and /boot grown." ;;
esac
ui msgbox "This card now starts the new system:\n\n    $mountfrom\n\nLeave the card in the SD slot.  Its $BOOTLABEL partition is the new system's /boot, so kernel updates there take effect at the next start.\n\n$after${kernel_note-}"
exit 0
