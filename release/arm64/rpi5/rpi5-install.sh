#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#

#
# rpi5-install -- install FreeBSD onto the SD card this live system booted
# from, keeping the card bootable by the Raspberry Pi 5 firmware.
#
# The live system runs entirely from memory, so the card is free to be
# rewritten.  Its first slice is the FAT partition the VPU firmware boots
# from and is kept; its second slice holds the install payload and is
# replaced by the new system.  So the payload is copied into memory first,
# and nothing on the card is touched until the person at the console has
# confirmed.
#
# Afterwards the card boots the installed system: rpi5-bootimg(8) writes the
# installed kernel into boot.ufs on the FAT partition and switches
# config.txt's initramfs line to it.  The live image, mfsroot.ufs, stays on
# the FAT partition as a rescue system.
#
# The install steps themselves are bsdinstall's own, in the order its "auto"
# script runs them, minus partitioning (done here) and bootconfig (this
# board has no EFI).
#

BSDCFG_SHARE="/usr/share/bsdconfig"
. $BSDCFG_SHARE/common.subr || exit 1

: ${BSDDIALOG_OK=0}
: ${BSDDIALOG_CANCEL=1}

. /usr/libexec/rpi5/install.conf

BSDINSTALL=/usr/sbin/bsdinstall
MEDIA=/media/rpi5inst
FATLABEL=RPI5BOOT
: ${TMPDIR:=/tmp}
: ${BSDINSTALL_CHROOT:=/mnt}
: ${BSDINSTALL_TMPETC:=${TMPDIR}/bsdinstall_etc}
: ${BSDINSTALL_TMPBOOT:=${TMPDIR}/bsdinstall_boot}
PAYLOAD=${TMPDIR}/rpi5-payload
LOG=${TMPDIR}/bsdinstall_log
export TMPDIR BSDINSTALL_CHROOT BSDINSTALL_TMPETC BSDINSTALL_TMPBOOT
export PATH_FSTAB=${BSDINSTALL_TMPETC}/fstab
BACKTITLE="${OSNAME} Installer -- Raspberry Pi 5"

msg()
{
	bsddialog --backtitle "${BACKTITLE}" --title "$1" --msgbox "$2" 0 0
}

info()
{
	bsddialog --backtitle "${BACKTITLE}" --title "$1" --infobox "$2" 0 0
}

error()
{
	msg "Error" "$1"
	exit 1
}

mkdir -p "${BSDINSTALL_TMPETC}" "${BSDINSTALL_TMPBOOT}"

#
# Find the card.  The FAT slice carries a label the image build gave it, so
# the disk is whatever that label lives on; nothing is guessed from device
# names.
#
FATPROV=$(glabel status -s | awk -v l="msdosfs/${FATLABEL}" \
    '$1 == l { print $3; exit }')
case ${FATPROV} in
*s1)	DISK=${FATPROV%s1} ;;
*)	error "Cannot find the boot partition (msdosfs/${FATLABEL}).\n\nThis installer only installs onto the SD card it was started from." ;;
esac

#
# Choose what to install from, among what the card carries.
#
set --
if [ -d "${MEDIA}/usr/freebsd-packages/offline" ]; then
	set -- "$@" pkgbase "Base system packages (recommended)"
fi
if [ -f "${MEDIA}/usr/freebsd-dist/MANIFEST" ]; then
	set -- "$@" dists "Distribution sets (base.txz, kernel.txz)"
fi
[ $# -gt 0 ] ||
    error "No install payload found under ${MEDIA}.\n\nIs the card's second slice intact?"

exec 5>&1
METHOD=$(bsddialog --backtitle "${BACKTITLE}" --title "Installation method" \
    --menu "Install ${OSNAME} from:" 0 0 0 "$@" 2>&1 1>&5)
rc=$?
exec 5>&-
[ ${rc} -eq ${BSDDIALOG_OK} ] || exit 1

case ${METHOD} in
pkgbase) SRC=${MEDIA}/usr/freebsd-packages/offline ;;
dists)	 SRC=${MEDIA}/usr/freebsd-dist ;;
*)	 exit 1 ;;
esac

#
# The payload has to be copied into memory, because the slice it is on is
# about to be replaced.  /tmp is a tmpfs, so check it will fit before
# starting rather than fail half way -- a 2 GB board is the tight case.
#
need_kib=$(du -sk "${SRC}" | awk '{ print $1 }')
have_kib=$(df -k "${TMPDIR}" | awk 'NR == 2 { print $4 }')
if [ "${need_kib}" -ge $((have_kib - 65536)) ]; then
	error "The ${METHOD} payload needs $((need_kib / 1024)) MiB of memory and only $((have_kib / 1024)) MiB is free.\n\nTry the other installation method."
fi

bsddialog --backtitle "${BACKTITLE}" --title "Destination" --defaultno \
    --yesno "${OSNAME} will be installed on ${DISK}.\n\nThe firmware partition (${DISK}s1) is kept.  EVERYTHING ELSE ON ${DISK} WILL BE ERASED, including the install media on ${DISK}s2, which is copied into memory first.\n\nContinue?" 0 0 ||
    exit 1

info "Copying" "Copying the ${METHOD} payload ($((need_kib / 1024)) MiB) into memory..."
rm -rf "${PAYLOAD}"
mkdir -p "${PAYLOAD}/src"
cp -Rp "${SRC}/." "${PAYLOAD}/src/" || error "Copying the payload failed."

if [ "${METHOD}" = pkgbase ]; then
	mkdir -p "${PAYLOAD}/repos"
	printf 'FreeBSD-base: {\n  url: "file://%s",\n  enabled: yes\n}\n' \
	    "${PAYLOAD}/src" > "${PAYLOAD}/repos/FreeBSD-base-offline.conf"
fi

umount "${MEDIA}" 2>/dev/null
if mount -p | awk -v m="${MEDIA}" '$2 == m { found = 1 } END { exit !found }'; then
	error "Could not unmount the install media at ${MEDIA}."
fi

#
# Replace the second slice with the new system.  The first slice, and the
# MBR entry for it, are left exactly as they are.
#
info "Partitioning" "Creating the ${OSNAME} slice on ${DISK}..."
{
	gpart destroy -F "${DISK}s2" 2>/dev/null
	gpart delete -i 2 "${DISK}" &&
	gpart add -t freebsd "${DISK}" &&
	gpart create -s bsd "${DISK}s2" &&
	gpart add -t freebsd-ufs -a 64k "${DISK}s2" &&
	newfs -U -t -L rootfs "/dev/${DISK}s2a"
} >> "${LOG}" 2>&1 ||
    error "Partitioning ${DISK} failed; see ${LOG}."

{
	printf '# Device\t\tMountpoint\tFStype\tOptions\t\tDump\tPass#\n'
	printf '/dev/ufs/rootfs\t\t/\t\tufs\trw\t\t1\t1\n'
	printf '/dev/msdosfs/%s\t/boot/efi\tmsdosfs\trw,noatime\t0\t0\n' \
	    "${FATLABEL}"
	printf 'tmpfs\t\t\t/tmp\t\ttmpfs\trw,mode=1777\t0\t0\n'
} > "${PATH_FSTAB}"

${BSDINSTALL} mount || error "Failed to mount the new file systems."

case ${METHOD} in
pkgbase)
	BSDINSTALL_PKG_REPOS_DIR=${PAYLOAD}/repos \
	BSDINSTALL_PKGBASE_KERNEL=${RPI5_KERNEL_PACKAGE} \
	    ${BSDINSTALL} pkgbase ||
	    error "Installation of base system packages failed."
	;;
dists)
	export BSDINSTALL_DISTDIR=${PAYLOAD}/src
	export DISTRIBUTIONS="kernel.txz base.txz"
	${BSDINSTALL} checksum || error "Distribution checksum failed."
	${BSDINSTALL} distextract || error "Distribution extract failed."
	;;
esac

if [ -z "${BSDINSTALL_SKIP_HOSTNAME}" ]; then
	${BSDINSTALL} hostname || error "Setting the hostname failed."
fi
${BSDINSTALL} rootpass || error "Could not set the root password."
${BSDINSTALL} netconfig		# the user may cancel
[ -n "${BSDINSTALL_SKIP_TIME}" ] || ${BSDINSTALL} time
[ -n "${BSDINSTALL_SKIP_SERVICES}" ] || ${BSDINSTALL} services
[ -n "${BSDINSTALL_SKIP_HARDENING}" ] || ${BSDINSTALL} hardening
[ -n "${BSDINSTALL_SKIP_FIRMWARE}" ] || ${BSDINSTALL} firmware
if [ -z "${BSDINSTALL_SKIP_USERS}" ]; then
	if bsddialog --backtitle "${BACKTITLE}" --title "Add User Accounts" \
	    --yesno "Would you like to add users to the installed system now?" 0 0; then
		${BSDINSTALL} adduser
	fi
fi
[ -n "${BSDINSTALL_SKIP_FINALCONFIG}" ] || ${BSDINSTALL} finalconfig
${BSDINSTALL} config || error "Failed to save the configuration."

#
# Make the card boot what was just installed.  The installed system's own
# rpi5-bootimg is used, so the image is written the way that system will
# rewrite it on its next kernel update.
#
info "Boot image" "Writing the kernel boot image to the firmware partition..."
sh "${BSDINSTALL_CHROOT}/usr/sbin/rpi5-bootimg" -c -r "${BSDINSTALL_CHROOT}" \
    >> "${LOG}" 2>&1 ||
    error "Writing boot.ufs failed; see ${LOG}.\n\nThe card still boots the live system."

${BSDINSTALL} entropy
${BSDINSTALL} umount

rm -rf "${PAYLOAD}"

msg "Installed" "${OSNAME} is installed on ${DISK}s2a and the card now boots it.\n\nThe live system stays on the firmware partition as mfsroot.ufs.  To start it again, edit config.txt there and change \"initramfs boot.ufs\" to \"initramfs mfsroot.ufs\"."
exit 0
