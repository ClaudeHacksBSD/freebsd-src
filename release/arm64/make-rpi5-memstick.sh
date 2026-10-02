#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#
# This script generates the Raspberry Pi 5 installer card image: what
# memstick.img is for a machine with EFI firmware.
#
# Usage: make-rpi5-memstick.sh <manifest> <image filename>
#
# <manifest> is the METALOG of an installer tree, as "make disc1" in
# release/ leaves it; the tree is the directory the manifest is in.
#
# The Raspberry Pi 5 firmware starts the FreeBSD loader, rpiboot, from a FAT
# partition, and rpiboot reads /boot from a UFS partition of the same card
# (loader.rpiboot(8)).  The image is an MBR disk, as the other arm images
# are, each UFS inside a BSD label:
#
#	s1   FAT16, type 0x0c, active, from sector 63: what the firmware
#	     reads: config.txt, the device trees, overlays/, rpiboot.bin, and
#	     loader.env for the loader (rootdev=disk0s2a:)
#	s2a  UFS2 "freebsd-boot": /boot.  The tree's /boot with its files at
#	     the top and a "boot -> ." link for the loader: the kernel and its
#	     modules, the loader's scripts, loader.conf.  The installer mounts
#	     it at /boot, and so does the system it installs, so that
#	     installkernel there writes what the loader reads.
#	s3a  UFS2 "freebsd-install", last so that the boot partition can grow
#	     into its space: the rest of the tree, with bsdinstall started by
#	     /etc/rc.local, and local.post-configure as a link to rpi5boot,
#	     which makes the card boot what was installed.
#
# rpiboot.bin also carries a small memory disk with a kernel on it.  The
# loader falls back to it, and starts the installer from there, when it
# cannot use the boot partition.
#
# From the environment:
#
#	RPI5_FWDIR   the Raspberry Pi firmware's Pi 5 device trees, the
#	             overlays/ directory and the licence files
#	             (/usr/local/share/rpi-firmware, where sysutils/rpi-firmware
#	             installs them)
#	RPI5_CYWDIR  the CYW43455 WiFi firmware: brcmfmac43455-sdio.bin, .txt
#	             and .clm_blob.  No default.
#	RPI5_OVLDIR  the overlays config.txt names with dtoverlay=
#	             (<tree>/boot/dtb/overlays)
#	RPI5_LOADER  the loader image (<tree>/boot/rpiboot.bin); only its
#	             memory disk is replaced
#	RPI5_MD_SIZE that loader's MD_IMAGE_SIZE in bytes (20971520)
#
# Nothing in the tree is changed.  What the partitions get beyond the tree
# goes in through the manifests (contents=, link=).
#

set -e

if [ "$(uname -s)" = "FreeBSD" ]; then
	PATH=/bin:/usr/bin:/sbin:/usr/sbin
	export PATH
fi

scriptdir=$(dirname $(realpath $0))
. ${scriptdir}/../scripts/tools.subr

if [ $# -ne 2 ]; then
	echo "make-rpi5-memstick.sh /path/to/manifest /path/to/image/file"
	exit 1
fi

die() {
	echo "make-rpi5-memstick.sh: $*" >&2
	exit 1
}

if [ ! -f ${1} ]; then
	die "${1} must be the manifest (METALOG) of an installer tree"
fi
METALOG=$(realpath ${1})
BASEBITSDIR=$(dirname ${METALOG})

case ${2} in
/*)	IMAGE=${2} ;;
*)	IMAGE=$(pwd)/${2} ;;
esac
if [ -e ${IMAGE} ]; then
	die "won't overwrite ${2}"
fi

DATADIR=${scriptdir}/rpi5
FWDIR=${RPI5_FWDIR:-/usr/local/share/rpi-firmware}
CYWDIR=${RPI5_CYWDIR}
OVLDIR=${RPI5_OVLDIR:-${BASEBITSDIR}/boot/dtb/overlays}
LOADER=${RPI5_LOADER:-${BASEBITSDIR}/boot/rpiboot.bin}
MD_SIZE=${RPI5_MD_SIZE:-20971520}

FAT_SIZE=100m
BOOT_SIZE=512m
BOOTLABEL=freebsd-boot
INSTLABEL=freebsd-install

# What the firmware needs from its own distribution for a Pi 5.
FW_DTBS="bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-d-rpi-5-b.dtb"
FW_OVERLAYS="bcm2712d0.dtbo"
FW_LICENCES="LICENCE.broadcom COPYING.linux"
CYW_FILES="brcmfmac43455-sdio.bin brcmfmac43455-sdio.txt \
    brcmfmac43455-sdio.clm_blob"

for f in config.txt loader.env loader.conf.rpi5 loader.conf.installer \
    loader.conf.fallback rpiboot-md.sh; do
	[ -f ${DATADIR}/${f} ] || die "${DATADIR}/${f} not found"
done
for f in etc/rc.local usr/sbin/bsdinstall usr/libexec/bsdinstall/rpi5boot \
    boot/kernel/kernel boot/lua/loader.lua boot/defaults/loader.conf; do
	[ -e ${BASEBITSDIR}/${f} ] || die "the tree has no ${f}"
done
[ -f ${LOADER} ] || die "${LOADER} not found"
for f in ${FW_DTBS} ${FW_LICENCES}; do
	[ -f ${FWDIR}/${f} ] ||
	    die "${FWDIR}/${f} not found; set RPI5_FWDIR (sysutils/rpi-firmware)"
done
for f in ${FW_OVERLAYS}; do
	[ -f ${FWDIR}/overlays/${f} ] || die "${FWDIR}/overlays/${f} not found"
done
[ -n "${CYWDIR}" ] || die "RPI5_CYWDIR is not set: the CYW43455 firmware files"
for f in ${CYW_FILES}; do
	[ -f ${CYWDIR}/${f} ] || die "${CYWDIR}/${f} not found"
done

WORK=$(mktemp -d ${TMPDIR:-/tmp}/rpi5-memstick.XXXXXX)
cleanup() {
	rm -rf ${WORK}
	rm -f ${IMAGE}.fat ${IMAGE}.boot ${IMAGE}.install \
	    ${IMAGE}.s2 ${IMAGE}.s3
}
trap cleanup EXIT

# The loader, with its fallback memory disk: the loader's scripts, the
# kernel without its symbol table so that it fits, and the WiFi firmware,
# which loader.conf preloads because cyw(4) attaches before root is mounted.
# The files' owners are those of this build; nothing reads them but the
# loader.
md=${WORK}/md
mkdir -p ${md}/boot/lua ${md}/boot/defaults ${md}/boot/images \
    ${md}/boot/loader.conf.d ${md}/boot/kernel ${md}/boot/firmware/cyw43455
cp ${BASEBITSDIR}/boot/lua/*.lua ${md}/boot/lua/
cp ${BASEBITSDIR}/boot/defaults/loader.conf ${md}/boot/defaults/
cp ${BASEBITSDIR}/boot/images/*.png ${md}/boot/images/
cp ${DATADIR}/loader.conf.fallback ${md}/boot/loader.conf
grep -q '^kernel="kernel"$' ${md}/boot/loader.conf ||
    die "loader.conf.fallback does not boot /boot/kernel/kernel"
for f in ${CYW_FILES}; do
	cp ${CYWDIR}/${f} ${md}/boot/firmware/cyw43455/
done
${STRIPBIN:-strip} -o ${md}/boot/kernel/kernel ${BASEBITSDIR}/boot/kernel/kernel
chmod 555 ${md}/boot/kernel/kernel
${MAKEFS} -t ffs -s ${MD_SIZE} -o version=2 -o bsize=8192 -o fsize=1024 \
    ${WORK}/md.img ${md} > /dev/null ||
    die "the fallback memory disk does not fit in ${MD_SIZE} bytes"

fat=${WORK}/fat
mkdir -p ${fat}/overlays
sh ${DATADIR}/rpiboot-md.sh ${LOADER} ${WORK}/md.img ${fat}/rpiboot.bin \
    > ${WORK}/md.log || { cat ${WORK}/md.log >&2; die "no memory disk in ${LOADER}"; }
# The firmware wants an arm64 Image: "ARM\x64" at offset 56.
magic=$(od -A n -t x1 -j 56 -N 4 ${fat}/rpiboot.bin | tr -d ' \n')
[ "${magic}" = "41524d64" ] || die "${LOADER} has no arm64 Image header"
grep -q -a "has no /boot/lua/loader.lua" ${fat}/rpiboot.bin ||
    die "${LOADER} is not a loader that reads the card"

# The FAT.
for f in ${FW_DTBS} ${FW_LICENCES}; do
	cp ${FWDIR}/${f} ${fat}/
done
for f in ${FW_OVERLAYS}; do
	cp ${FWDIR}/overlays/${f} ${fat}/overlays/
done
cp ${DATADIR}/config.txt ${DATADIR}/loader.env ${fat}/
grep -q -x 'rootdev=disk0s2a:' ${fat}/loader.env ||
    die "loader.env does not name the boot partition this script makes"
for o in $(sed -n 's/^dtoverlay=\([^,[:space:]]*\).*/\1/p' ${fat}/config.txt); do
	[ -f ${OVLDIR}/${o}.dtbo ] ||
	    die "config.txt wants overlay ${o}; ${OVLDIR}/${o}.dtbo not found"
	cp ${OVLDIR}/${o}.dtbo ${fat}/overlays/
done
k=$(sed -n 's/^kernel=//p' ${fat}/config.txt | tail -1)
[ -n "${k}" ] && [ -f ${fat}/${k} ] ||
    die "config.txt kernel=\"${k}\" is not on the FAT"
${MAKEFS} -t msdos -o fat_type=16 -o volume_label=RPI5BOOT -s ${FAT_SIZE} \
    ${IMAGE}.fat ${fat} > /dev/null

# loader.conf for the boot partition while it boots the installer: the
# board's settings, then the installer's.  rpi5boot rewrites it after an
# install.
{
	echo "# loader.conf on the SD card's ${BOOTLABEL} partition, which is /boot."
	echo "# As built: it boots the installer.  An install rewrites it."
	echo
	grep -v -E '^[[:space:]]*(#|$)' ${DATADIR}/loader.conf.rpi5
	cat ${DATADIR}/loader.conf.installer
} > ${WORK}/loader.conf
grep -q "^vfs.root.mountfrom=\"ufs:/dev/ufs/${INSTLABEL}\"\$" ${WORK}/loader.conf ||
    die "loader.conf.installer does not root the installer at ufs/${INSTLABEL}"

# The boot partition: the tree's ./boot/... entries, moved to the top.
own="uname=root gname=wheel"
{
	echo ". type=dir ${own} mode=0755"
	sed -n 's|^\./boot/|./|p' ${METALOG} |
	    grep -v -E '^\./loader\.conf[[:space:]]'
	echo "./boot type=link ${own} mode=0755 link=."
	echo "./loader.conf type=file ${own} mode=0644 contents=${WORK}/loader.conf"
	echo "./loader.conf.rpi5 type=file ${own} mode=0444 contents=${DATADIR}/loader.conf.rpi5"
	grep -q -E '^\./boot/firmware[[:space:]]' ${METALOG} ||
	    echo "./firmware type=dir ${own} mode=0755"
	echo "./firmware/cyw43455 type=dir ${own} mode=0755"
	for f in ${CYW_FILES}; do
		echo "./firmware/cyw43455/${f} type=file ${own} mode=0444 contents=${CYWDIR}/${f}"
	done
} > ${WORK}/METALOG.boot
(cd ${BASEBITSDIR}/boot && ${MAKEFS} -D -N ${BASEBITSDIR}/etc -B little \
    -s ${BOOT_SIZE} -o label=${BOOTLABEL} -o version=2 -o softupdates=1 \
    ${IMAGE}.boot ${WORK}/METALOG.boot) > ${WORK}/makefs.log 2>&1 ||
    { tail -20 ${WORK}/makefs.log >&2; die "makefs of the boot partition failed"; }

# The installer: everything else, with /boot as an empty mount point.
{
	echo "/dev/ufs/${INSTLABEL} / ufs ro,noatime 1 1"
	echo "/dev/ufs/${BOOTLABEL} /boot ufs ro,noatime 2 2"
} > ${WORK}/fstab
echo 'root_rw_mount="NO"' > ${WORK}/rc.conf.local
{
	grep -v -E '^\./boot/' ${METALOG}
	echo "./etc/fstab type=file ${own} mode=0644 contents=${WORK}/fstab"
	echo "./etc/rc.conf.local type=file ${own} mode=0644 contents=${WORK}/rc.conf.local"
	echo "./usr/libexec/bsdinstall/local.post-configure type=link ${own} mode=0755 link=rpi5boot"
} > ${WORK}/METALOG.install
(cd ${BASEBITSDIR} && ${MAKEFS} -D -N ${BASEBITSDIR}/etc -B little \
    -o label=${INSTLABEL} -o version=2 \
    ${IMAGE}.install ${WORK}/METALOG.install) > ${WORK}/makefs.log 2>&1 ||
    { tail -20 ${WORK}/makefs.log >&2; die "makefs of the installer failed"; }

# The disk.  255 heads and 63 sectors, the geometry the other arm images
# are made with: the FAT then starts at sector 63, with its CHS fields
# filled in.  Without a geometry mkimg starts it at sector 1.
${MKIMG} -s bsd -p freebsd-ufs:=${IMAGE}.boot -o ${IMAGE}.s2
${MKIMG} -s bsd -p freebsd-ufs:=${IMAGE}.install -o ${IMAGE}.s3
${MKIMG} -s mbr -a 1 -H 255 -T 63 \
    -p fat32lba:=${IMAGE}.fat \
    -p freebsd:=${IMAGE}.s2 \
    -p freebsd:=${IMAGE}.s3 \
    -o ${IMAGE}
