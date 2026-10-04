.PATH: ${SRCTOP}/sys/arm64/broadcom/bcm2712

KMOD=	rpi_fw_cpufreq
SRCS=	rpi_fw_cpufreq.c

SRCS+=	bus_if.h \
	clknode_if.h \
	cpufreq_if.h \
	device_if.h \
	ofw_bus_if.h \
	opt_platform.h

.include <bsd.kmod.mk>
