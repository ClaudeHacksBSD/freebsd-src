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
 * Written from a functional specification of the BCM2712 PM block.
 */

#ifndef _ARM64_BROADCOM_BCM2712_BCM2712_PM_H_
#define	_ARM64_BROADCOM_BCM2712_BCM2712_PM_H_

#include <dev/ofw/openfirm.h>

/*
 * Power domains of the BCM2712 PM block ("brcm,bcm2712-pm").
 *
 * FreeBSD has no power-domain framework, so the PM driver offers its
 * domains through the functions below.  A consumer names a domain the way
 * its device-tree node does: an entry of its "power-domains" property, a
 * phandle of the PM node followed by one cell, the domain number.
 *
 * Domain numbers are those of the "brcm,bcm2835-pm" binding.  The driver
 * accepts only the domains it implements; any other cell value, a cell
 * count other than one, or a phandle that is not an attached PM block is
 * refused when the handle is requested.
 *
 * A handle belongs to one consumer.  Each handle is either enabled or not;
 * the driver counts the enabled handles of each domain, switches the domain
 * on when that count leaves zero and off when it returns to zero.
 * Enabling an enabled handle, or disabling a disabled one, changes nothing.
 * Releasing an enabled handle disables it first.  The PM driver refuses to
 * detach while any handle exists.
 *
 * All four functions may sleep: call them from thread context.  Enabling
 * the V3D domain powers its parent domain on first, and fails with
 * ETIMEDOUT, leaving the handle disabled, if that does not complete.
 *
 * Reset lines of the same block are offered through hwreset(9), with the
 * reset numbers of the same binding.
 */

/* Power-domain cells. */
#define	BCM2712_PM_DOMAIN_GRAFX_V3D	1

/* Reset cells. */
#define	BCM2712_PM_RESET_V3D		0

struct bcm2712_pm_domain;
typedef struct bcm2712_pm_domain *bcm2712_pm_domain_t;

/*
 * Get a handle for entry 'idx' of the "power-domains" property of 'cnode',
 * or of the consumer's own node if 'cnode' is 0 or less.
 */
int	bcm2712_pm_domain_get_by_ofw_idx(device_t consumer, phandle_t cnode,
	    int idx, bcm2712_pm_domain_t *domp);
int	bcm2712_pm_domain_enable(bcm2712_pm_domain_t dom);
int	bcm2712_pm_domain_disable(bcm2712_pm_domain_t dom);
void	bcm2712_pm_domain_release(bcm2712_pm_domain_t dom);

#endif /* _ARM64_BROADCOM_BCM2712_BCM2712_PM_H_ */
