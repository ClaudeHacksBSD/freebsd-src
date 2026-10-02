#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#
# The post-install step of the Raspberry Pi 5 installer card
# (release/arm64/make-rpi5-memstick.sh): rpi5boot makes the card boot the
# system that was just installed, and the other files are what it copies
# into that system or onto the card.

SCRIPTS=	rpi5boot.sh
FILES=		rpi5-installer-entry.lua \
		rpi5-recycle.rc \
		rpi5-recycle.sh

BINDIR=		${LIBEXECDIR}/bsdinstall
FILESDIR=	${LIBEXECDIR}/bsdinstall

MAN=

.include <bsd.prog.mk>
