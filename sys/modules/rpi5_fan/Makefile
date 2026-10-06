#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#

.PATH: ${SRCTOP}/sys/arm64/broadcom/bcm2712

KMOD=	rpi5_fan
SRCS=	rpi5_fan.c rpi5_nn.c
SRCS+=	bus_if.h device_if.h

.include <bsd.kmod.mk>
