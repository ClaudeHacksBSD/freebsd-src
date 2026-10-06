#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2026 Jeremy McMillan
#

.PATH: ${SRCTOP}/sys/arm64/broadcom/bcm2712

KMOD=	brcmstb_gpio
SRCS=	brcmstb_gpio.c
SRCS+=	bus_if.h device_if.h gpio_if.h ofw_bus_if.h
SRCS+=	opt_platform.h

.include <bsd.kmod.mk>
