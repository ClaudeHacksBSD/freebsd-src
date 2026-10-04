/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2026 The FreeBSD Project.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * The views and conclusions contained in the software and documentation are
 * those of the authors and should not be interpreted as representing
 * official policies, either expressed or implied, of the FreeBSD Project.
 *
 * Author: Jeremy McMillan
 * Author: Claude Opus 5.5
 * Author: FreeBSD Contributors
 */

/*
 * Written from a functional specification of the Raspberry Pi firmware
 * clock interface.
 */

#ifndef _ARM64_BROADCOM_BCM2712_RPI_FW_CLK_H_
#define	_ARM64_BROADCOM_BCM2712_RPI_FW_CLK_H_

#include <dev/clk/clk.h>

/*
 * The name of the clock this provider registers for the V3D GPU, firmware
 * clock 5, for a consumer whose device-tree node does not name its clock.
 */
#define	RPI_FW_CLK_NAME_V3D	"rpi_fw_v3d"

/* Bits of the firmware's clock state word. */
#define	RPI_FW_CLK_STATE_ON	0x00000001	/* the clock is running */
#define	RPI_FW_CLK_STATE_ABSENT	0x00000002	/* no such clock */

/*
 * Ask the firmware, now, for the state word and the rate in Hz of a clock
 * obtained from the "raspberrypi,firmware-clocks" provider.  Neither value
 * comes from a cache: clk_get_freq() may return a rate the clock framework
 * saved earlier, while the firmware changes its clocks on its own.
 *
 * Returns ENXIO if 'clk' is not one of this provider's clocks, or the
 * mailbox error.  Sleeps: call from thread context.
 */
int	rpi_fw_clk_query(clk_t clk, uint32_t *state, uint32_t *rate);

/*
 * Ask the firmware, now, for the highest rate in Hz it allows the clock.
 * Same errors as rpi_fw_clk_query().
 */
int	rpi_fw_clk_max_rate(clk_t clk, uint32_t *rate);

#endif /* _ARM64_BROADCOM_BCM2712_RPI_FW_CLK_H_ */
