#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#

.PATH: ${SRCTOP}/sys/arm64/broadcom/bcm2712

KMOD=	bcm2712_pcie
SRCS=	bcm2712_pcie.c
SRCS+=	bus_if.h device_if.h ofw_bus_if.h pci_if.h
SRCS+=	opt_platform.h

EXPORT_SYMS=	bcm2712_pcie_register_rp1_intr
EXPORT_SYMS+=	bcm2712_pcie_deregister_rp1_intr

.include <bsd.kmod.mk>
