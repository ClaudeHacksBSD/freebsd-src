#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#
# rpiboot-md.sh -- put a memory-disk image into an rpiboot loader image,
# leaving the loader's code as it is.
#
#	sh rpiboot-md.sh IN.bin NEW.img OUT.bin
#
# The loader (stand/arm64/rpiboot) reserves room for a memory disk, md0:,
# inside its own image.  Building the loader with MFS_IMAGE fills it at link
# time; this fills or refills it afterwards, in a loader that is already
# built, so that one loader binary can carry different memory disks.  The
# result differs from IN.bin in the memory disk and nowhere else.
#
# NEW.img must be a UFS2 image of exactly the loader's MD_IMAGE_SIZE
# (makefs -s).
#
# How the region is found.  stand/common/md.c reserves MD_IMAGE_SIZE bytes
# followed by the string "MFS Filesystem had better STOP here".  The start
# string ("MFS Filesystem goes here") is gone once an image is embedded,
# but the end string never is, so the region is the size of NEW.img, ending
# at that string.  Its offset varies from one build of the loader to the
# next.  The guess is checked: what is there now must be an unused region
# (the start string) or a UFS2 image (the superblock magic), and the script
# stops otherwise.
#
# Changes nothing but OUT.bin.

set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 3 ] || { echo "usage: $0 IN.bin NEW.img OUT.bin" >&2; exit 2; }
IN=$1
IMG=$2
OUT=$3
[ -f "$IN" ] || die "$IN not found"
[ -f "$IMG" ] || die "$IMG not found"
[ "$IN" != "$OUT" ] || die "OUT.bin must not be IN.bin"

END_MARK="MFS Filesystem had better STOP here"
START_MARK="MFS Filesystem goes here"
# UFS2: superblock at 65536, fs_magic (0x19540119, little-endian) at 1372.
MAGIC_OFF=$((65536 + 1372))
MAGIC="19015419"

magic_at() {	# file offset -> 8 hex digits
	tail -c +$(($2 + 1)) "$1" | head -c 4 | hexdump -v -e '4/1 "%02x"'
}

size=$(stat -f %z "$IMG")
[ $((size % 512)) -eq 0 ] || die "$IMG is $size bytes, not a multiple of 512"
[ "$(magic_at "$IMG" $MAGIC_OFF)" = "$MAGIC" ] || die "$IMG is not a UFS2 image"

ends=$(grep -abo "$END_MARK" "$IN" | cut -d: -f1)
set -- $ends
[ $# -eq 1 ] || die "$IN has $# end markers, want 1: not an rpiboot image with a memory disk?"
end=$1
start=$((end - size))
[ $start -gt 0 ] || die "$IMG ($size bytes) is larger than everything before the end marker"

# Is that really where the region starts?
if [ "$(tail -c +$((start + 1)) "$IN" | head -c ${#START_MARK})" = "$START_MARK" ]; then
	was="unused"
elif [ "$(magic_at "$IN" $((start + MAGIC_OFF)))" = "$MAGIC" ]; then
	was="a UFS2 image"
else
	die "no memory disk at offset $start of $IN: is $IMG the loader's MD_IMAGE_SIZE ($size bytes)?"
fi

{
	head -c "$start" "$IN"
	cat "$IMG"
	tail -c +$((end + 1)) "$IN"
} >"$OUT"
[ "$(stat -f %z "$OUT")" -eq "$(stat -f %z "$IN")" ] ||
    die "$OUT is not the size of $IN"

# Prove it: outside the region nothing changed, inside it is NEW.img.
a=$(head -c "$start" "$IN" | sha256 -q)
b=$(head -c "$start" "$OUT" | sha256 -q)
[ "$a" = "$b" ] || die "loader code before the memory disk changed"
a=$(tail -c +$((end + 1)) "$IN" | sha256 -q)
b=$(tail -c +$((end + 1)) "$OUT" | sha256 -q)
[ "$a" = "$b" ] || die "loader data after the memory disk changed"
a=$(tail -c +$((start + 1)) "$OUT" | head -c "$size" | sha256 -q)
[ "$a" = "$(sha256 -q "$IMG")" ] || die "the memory disk in $OUT is not $IMG"

echo "loader:  $IN ($(sha256 -q "$IN" | cut -c1-8)), code unchanged"
echo "md:      offset $start, $size bytes, was $was, now $IMG"
echo "image:   $OUT"
echo "size:    $(stat -f %z "$OUT") bytes"
echo "sha256:  $(sha256 -q "$OUT")"
