# DTS files for the 32-bit and 64-bit arm-based Raspberry Pi family of devices
.if ${MACHINE_CPUARCH} == "arm"
DTSO=	\
	spigen-rpi2.dtso
.elif ${MACHINE_CPUARCH} == "aarch64"
DTSO=	\
	bcm2712-rpi5-pcie1.dtso \
	bcm2712-rpi5-pcie2.dtso \
	spigen-rpi3.dtso \
	spigen-rpi4.dtso
.endif

.include <bsd.dtb.mk>
