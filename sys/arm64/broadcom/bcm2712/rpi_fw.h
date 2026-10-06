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
 * rpi_fw -- the Raspberry Pi 5 VPU property mailbox, for other drivers.
 */

#ifndef _ARM64_BROADCOM_BCM2712_RPI_FW_H_
#define	_ARM64_BROADCOM_BCM2712_RPI_FW_H_

/*
 * Send one property tag to the VPU firmware and wait for its reply.
 *
 * val is the tag's value buffer and vallen its size in bytes; the buffer
 * must hold vallen rounded up to a multiple of 4.  The first inlen bytes
 * of val are the request.  On success the firmware's reply replaces the
 * contents of val.
 *
 * Calls are serialised against every other user of the mailbox.  The call
 * holds a sleep mutex while it polls the mailbox, so it is made from thread
 * context, never from an interrupt filter or with a spin lock held.
 *
 * Returns 0 on success, or:
 *	ENXIO		rpi_fw has not attached
 *	EINVAL		inlen exceeds vallen, or the buffer is too large
 *	ETIMEDOUT	the firmware did not answer
 *	EIO		the firmware's reply code was not success
 *	EOPNOTSUPP	the firmware did not mark the tag as answered
 *
 * A caller declares MODULE_DEPEND(<module>, rpi_fw, 1, 1, 1).
 */
int	rpi_fw_property(uint32_t tag, uint32_t *val, uint32_t vallen,
	    uint32_t inlen);

#endif /* _ARM64_BROADCOM_BCM2712_RPI_FW_H_ */
