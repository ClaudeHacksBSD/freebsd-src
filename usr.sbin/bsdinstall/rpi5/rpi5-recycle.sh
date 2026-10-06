#!/bin/sh
#-
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#
# rpi5-recycle.sh -- delete the installer's partition on the Raspberry Pi 5
# card, and grow the boot partition.
#
#	rpi5-recycle installer|card|none
#
#	installer   grow freebsd-boot into the space the installer had
#	card        grow freebsd-boot to the end of the card
#	none        delete the installer, grow nothing
#
# Run once by /usr/local/etc/rc.d/rpi5_recycle at the first boot of the
# installed system, where the installer cannot do it: the installer runs
# from the partition to be deleted.  The boot partition is mounted at /boot
# while this runs; gpart grows a partition that is in use, and growfs(8)
# grows a mounted UFS, as /etc/rc.d/growfs does to the root of the stock arm
# images.
#
# The card, as release/arm64/make-rpi5-memstick.sh makes it:
#
#	s1   FAT
#	s2   BSD label, a = UFS "freebsd-boot"
#	s3   BSD label, a = UFS "freebsd-install", last
#
# Both partitions are found by their UFS labels and must be on one disk,
# with the installer's slice after the boot slice.  Anything else and the
# script changes nothing.
#
# On success it removes itself, its rc.d script and its settings.
# Log: /var/log/rpi5-recycle.log (RPI5_RECYCLE_LOG).

BOOTLABEL=freebsd-boot
INSTLABEL=freebsd-install
LOG=${RPI5_RECYCLE_LOG:-/var/log/rpi5-recycle.log}
grow=${1:-none}

say() {
	echo "rpi5_recycle: $*"
	echo "$*" >>"$LOG" 2>/dev/null
}

die() {
	say "FAILED: $*  Nothing more is changed."
	exit 1
}

# The partition a UFS label is on: "ufs/freebsd-boot" -> "sdda0s2a".
label_part() {
	glabel status -s 2>/dev/null | awk -v l="ufs/$1" '$1 == l { print $3; exit }'
}

# "start size" of a slice, in sectors, from its disk's partition table.
slice_geom() {	# disk slice
	gpart show -p "$1" | awk -v s="$2" '$1 != "=>" && $3 == s { print $1, $2; exit }'
}

case $grow in
installer|card|none) ;;
*) die "unknown mode \"$grow\" (installer, card or none)." ;;
esac
say "$(date -u '+%Y-%m-%d %H:%M:%S UTC') grow=$grow"

bootpart=$(label_part $BOOTLABEL)
instpart=$(label_part $INSTLABEL)
[ -n "$bootpart" ] || die "no UFS labelled $BOOTLABEL."
if [ -z "$instpart" ]; then
	say "no UFS labelled $INSTLABEL: the installer is already gone"
else
	bootslice=${bootpart%[a-h]}
	instslice=${instpart%[a-h]}
	[ "$bootslice" != "$bootpart" ] && [ "$instslice" != "$instpart" ] ||
	    die "$bootpart or $instpart is not a BSD-label partition."
	disk=${bootslice%s[0-9]*}
	[ "$disk" != "$bootslice" ] && [ "${instslice%s[0-9]*}" = "$disk" ] ||
	    die "$bootslice and $instslice are not slices of one disk."
	bidx=${bootslice#"${disk}"s}
	iidx=${instslice#"${disk}"s}

	if mount -p | awk -v a="/dev/ufs/$INSTLABEL" -v b="/dev/$instpart" \
	    '$1 == a || $1 == b { found = 1 } END { exit !found }'; then
		die "the installer's partition is mounted."
	fi
	set -- $(slice_geom "$disk" "$bootslice")
	[ $# -eq 2 ] || die "cannot read $bootslice from $disk's partition table."
	bstart=$1
	bsize=$2
	set -- $(slice_geom "$disk" "$instslice")
	[ $# -eq 2 ] || die "cannot read $instslice from $disk's partition table."
	istart=$1
	isize=$2
	[ "$istart" -ge $((bstart + bsize)) ] ||
	    die "$instslice is not after $bootslice on $disk."
	say "disk $disk: $bootslice at $bstart+$bsize, $instslice at $istart+$isize"
	gpart show "$disk" >>"$LOG" 2>&1

	# The installer: the label inside its slice, then the slice.
	gpart destroy -F "$instslice" >>"$LOG" 2>&1
	gpart delete -i "$iidx" "$disk" >>"$LOG" 2>&1 ||
	    die "cannot delete $instslice."
	say "deleted $instslice"

	case $grow in
	installer)
		gpart resize -i "$bidx" -s $((istart + isize - bstart)) "$disk" >>"$LOG" 2>&1 ||
		    die "cannot grow $bootslice into the installer's space."
		;;
	card)
		gpart resize -i "$bidx" "$disk" >>"$LOG" 2>&1 ||
		    die "cannot grow $bootslice to the end of $disk."
		;;
	esac
	if [ "$grow" != "none" ]; then
		gpart resize -i 1 "$bootslice" >>"$LOG" 2>&1 ||
		    die "cannot grow $bootpart inside $bootslice."
		# By mount point if it is mounted: growfs must see that it is.
		fs=$(mount -p | awk -v a="/dev/ufs/$BOOTLABEL" -v b="/dev/$bootpart" \
		    '$1 == a || $1 == b { print $2; exit }')
		growfs -y "${fs:-/dev/$bootpart}" >>"$LOG" 2>&1 ||
		    die "growfs of $BOOTLABEL failed."
		say "grew $BOOTLABEL: $(df -h "${fs:-/dev/$bootpart}" 2>/dev/null | awk 'NR == 2 { print $2 }')"
	fi
	gpart show "$disk" >>"$LOG" 2>&1
fi

# Done for good.
rm -f /etc/rc.conf.d/rpi5_recycle /usr/local/etc/rc.d/rpi5_recycle
case $0 in
/usr/local/libexec/rpi5-recycle) rm -f "$0" ;;
esac
say "done"
exit 0
