#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#

.PATH: ${SRCTOP}/sys/arm64/broadcom/rp1

KMOD=	rp1_pcie2_recon
SRCS=	rp1_pcie2_recon.c
SRCS+=	bus_if.h device_if.h ofw_bus_if.h
SRCS+=	opt_platform.h

.include <bsd.kmod.mk>
