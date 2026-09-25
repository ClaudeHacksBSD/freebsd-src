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
# mkmfsroot.sh -- turn an installed world and kernel into the Raspberry Pi 5
# live/installer root image.
#
#	mkmfsroot.sh -k pkgname [-m maxmib] tree out.ufs
#
# tree is a DESTDIR that has had installworld, installkernel and
# distribution run into it (see RPI5.conf).  It is pruned in place to what a
# text-mode live system and the installer need, configured to run from
# memory, and written to out.ufs with makefs.
#
# The image is loaded by the VPU firmware from config.txt "initramfs", copied
# behind the kernel by rpiboot, and mounted by the kernel as md0.  It has to
# fit between 0x30000000 and the top of the first memory region, so it has a
# hard ceiling of 244 MiB; the build fails rather than produce an image that
# silently cannot boot.
#

set -e

MAXMIB=224
KERNPKG=
HERE=$(cd "$(dirname "$0")" && pwd)

usage()
{
	echo "usage: ${0##*/} -k kernel-package [-m maxmib] tree out.ufs" >&2
	exit 64
}

while getopts k:m: opt; do
	case ${opt} in
	k)	KERNPKG=${OPTARG} ;;
	m)	MAXMIB=${OPTARG} ;;
	*)	usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] && [ -n "${KERNPKG}" ] || usage
TREE=$1
OUT=$2

[ -x "${TREE}/bin/sh" ] && [ -f "${TREE}/boot/kernel/kernel" ] ||
    { echo "${TREE} does not hold a world and kernel" >&2; exit 1; }
[ "${MAXMIB}" -le 244 ] ||
    { echo "-m ${MAXMIB}: more than 244 MiB cannot be loaded" >&2; exit 1; }

#
# Prune.  What stays is what a person at a serial console needs to look
# around, bring up a network and install: the shells and base utilities,
# bsdinstall and bsddialog, pkg, the disk and filesystem tools, fetch and
# the network configuration tools.  The world was installed without the
# toolchain, tests, debug files, profiling and 32-bit libraries already;
# this removes what installworld has no knob for.
#
cd "${TREE}"
rm -rf \
    usr/include \
    usr/lib/debug \
    usr/libdata/pkgconfig \
    usr/share/dict \
    usr/share/doc \
    usr/share/examples \
    usr/share/games \
    usr/share/i18n \
    usr/share/info \
    usr/share/man \
    usr/share/nls \
    usr/share/openssl/man \
    usr/share/sendmail \
    usr/share/snmp \
    usr/tests \
    boot/efi boot/lua boot/uboot \
    rescue
find usr/lib -name '*.a' -delete
find usr/share/locale -mindepth 1 -maxdepth 1 \
    ! -name 'C.UTF-8' ! -name 'en_US.UTF-8' -exec rm -rf {} +

# The kernel's drivers are compiled in; modules are dead weight here, apart
# from the few that the live system or installer may reasonably load.
KEEP_KMODS="nullfs geom_eli crypto cryptodev"
for ko in boot/kernel/*.ko; do
	[ -e "${ko}" ] || continue
	m=${ko##*/}; m=${m%.ko}
	case " ${KEEP_KMODS} " in
	*" ${m} "*) ;;
	*) rm -f "${ko}" ;;
	esac
done
rm -f boot/kernel/*.debug boot/kernel/*.symbols boot/kernel/linker.hints
# Only the kernel, firmware for its drivers (cyw(4) reads its files from
# /boot/firmware/cyw43455) and the loader script stay under /boot.
find boot -mindepth 1 -maxdepth 1 ! -name kernel ! -name firmware \
    -exec rm -rf {} +

#
# Configure it to run from memory.
#
# The root is md0 and writable -- it is a copy in RAM -- so /var and /etc
# need no tmpfs overlays.  /tmp still gets a tmpfs, because the installer
# copies its payload there and that must not come out of the root's fixed
# size.
#
mkdir -p boot media/rpi5inst
cat > boot/loader.rc <<'EOF'
\ Raspberry Pi 5 live system and installer; read by rpiboot's simp
\ interpreter.  md0: is this image, and rpiboot_initrd_root makes it the
\ kernel's root as well.
set rpiboot_initrd_root=YES
set vfs.root.mountfrom=ufs:/dev/md0
set vfs.mountroot.timeout=10
load /boot/kernel/kernel
autoboot 5
EOF

cat > etc/fstab <<'EOF'
# Raspberry Pi 5 live system: root is the in-memory image, and the install
# payload is on the SD card's second slice.
/dev/md0		/		ufs	rw		0	0
/dev/ufs/RPI5INST	/media/rpi5inst	ufs	ro,failok	0	0
tmpfs			/tmp		tmpfs	rw,mode=1777	0	0
EOF

cat > etc/rc.conf <<'EOF'
hostname="rpi5-live"
hostid_enable="NO"
sendmail_enable="NONE"
cron_enable="NO"
growfs_enable="NO"
EOF
echo 'debug.witness.trace=0' >> etc/sysctl.conf

# Where bsdinstall looks for install media, pointed at the payload slice.
rm -rf usr/freebsd-dist usr/freebsd-packages
ln -s /media/rpi5inst/usr/freebsd-dist usr/freebsd-dist
ln -s /media/rpi5inst/usr/freebsd-packages usr/freebsd-packages

# DHCP writes resolv.conf here, as on the other install media.
ln -sf /tmp/bsdinstall_etc/resolv.conf etc/resolv.conf

install -m 0755 "${HERE}/rc.local" etc/rc.local
install -d -m 0755 usr/libexec/rpi5
install -m 0755 "${HERE}/rpi5-install.sh" usr/libexec/rpi5/rpi5-install
install -d -m 0755 usr/libexec/rpi5/bin
install -m 0755 "${HERE}/bin/bsdinstall" usr/libexec/rpi5/bin/bsdinstall
install -m 0644 "${HERE}/config.txt" usr/libexec/rpi5/config.txt
echo "RPI5_KERNEL_PACKAGE=\"${KERNPKG}\"" > usr/libexec/rpi5/install.conf

cd - >/dev/null

#
# Size it.  The live system writes logs and the installer writes its own
# state, so leave some room free on top of what is there; then refuse to
# produce anything the firmware cannot place.
#
used_kib=$(du -skx "${TREE}" | awk '{ print $1 }')
size_mib=$(( (used_kib * 5 / 4) / 1024 + 16 ))
if [ "${size_mib}" -gt "${MAXMIB}" ]; then
	echo "live root needs ${size_mib} MiB, over the ${MAXMIB} MiB budget;" \
	    "prune more in ${0##*/}" >&2
	exit 1
fi

rm -f "${OUT}"
makefs -t ffs -B little -s "${size_mib}m" \
    -o version=2,label=RPI5MFS,minfree=0,optimization=space \
    "${OUT}" "${TREE}"
echo "${OUT}: ${size_mib} MiB live root from ${used_kib} KiB of files"
