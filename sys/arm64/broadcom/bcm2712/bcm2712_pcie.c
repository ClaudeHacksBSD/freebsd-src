/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 2025 Jeremy McMillan
 * All rights reserved.
 *
 * bcm2712_pcie — BCM2712 PCIe2→RP1 interrupt router
 *
 * Routes the RP1 GEM Ethernet MAC's interrupt to rp1_eth.  This is not a PCIe
 * host controller driver: it exists only to own a device_t that can legally
 * call bus_setup_intr() on the GIC line the RP1 MSI arrives on, and to map
 * enough of the GEM to tell whether the GEM was the source.
 *
 * This driver acts as a filter-only handler: it reads CGEM_INT_STATUS and
 * dispatches to rp1_eth's ISR if the GEM fired.
 *
 * Discovery is by Device Tree, and registers are mapped by physical address,
 * the same way every other driver in this set reaches RP1.  On an FDT boot
 * RP1 is a PCI device behind bcm2712_pcib, and this driver attaches below
 * rp1pci, the RP1 PCI driver, once it has published BAR1: RP1's windows are
 * found relative to BAR1 (bcm2712_fdt.h).  The interrupt is the GEM's own
 * RP1 vector (interrupts = <6 4>, level), which rp1pci delivers as RP1's
 * interrupt controller and acknowledges after the filter (IACK) -- by then
 * rp1_eth's filter has masked the GEM.  RP1's INTA, GIC SPI 229, is not
 * used: it never fires on an FDT boot.
 *
 * This replaces an earlier ACPI attachment, which matched a _HID of "BCM2712"
 * injected into the RP1B scope by a hand-written DSDT override in
 * /boot/acpi_dsdt.aml.  That override lived in no repository, and the FDT the
 * firmware already publishes describes the same hardware.
 *
 * KPI exported for rp1_eth:
 *   void bcm2712_pcie_register_rp1_intr(driver_filter_t *filter, void *arg)
 *   void bcm2712_pcie_deregister_rp1_intr(void)
 *
 * References:
 *   sys/dev/cadence/if_cgem.c (CGEM_INT_STATUS definition)
 *   sys/arm64/broadcom/rp1/rp1_eth_var.h (RP1 physical address derivation)
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/bus.h>
#include <sys/rman.h>

#include <machine/atomic.h>
#include <machine/bus.h>
#include <machine/resource.h>

#include <dev/ofw/ofw_bus.h>
#include <dev/ofw/ofw_bus_subr.h>
#include <dev/ofw/openfirm.h>

#include "bcm2712_fdt.h"
#include "bcm2712_pcie.h"

/* GEM interrupt status register — checked in the filter to confirm GEM fired */
#define CGEM_INT_STATUS		0x024
#define CGEM_INT_RX_COMPLETE	(1u << 1)
#define CGEM_INT_RX_USED_READ	(1u << 2)
#define CGEM_INT_TX_COMPLETE	(1u << 7)
#define CGEM_INT_TX_USED_READ	(1u << 3)
#define CGEM_INT_HRESP_NOT_OK	(1u << 11)
#define CGEM_INT_RX_OVERRUN	(1u << 10)
#define CGEM_INT_ANY		(CGEM_INT_RX_COMPLETE | CGEM_INT_RX_USED_READ | \
				 CGEM_INT_TX_COMPLETE | CGEM_INT_TX_USED_READ | \
				 CGEM_INT_HRESP_NOT_OK | CGEM_INT_RX_OVERRUN)

/*
 * RP1 register windows, as offsets into RP1's peripheral BAR (BAR1).  The
 * GEM is resolved from its node against the published BAR1, and
 * GEM_MAC_OFFSET is the fallback.
 *
 * eth_cfg, at 0x104000, is not mapped here: nothing in this driver uses it.
 * No device tree describes it; see rp1_eth_cfg.c.
 */
#define GEM_MAC_OFFSET		0x100000	/* ethernet@100000 */
#define GEM_MAC_SIZE		0x1000

/*
 * RP1 GEM interrupt.  ethernet@100000 has interrupts = <6 4> against rp1's
 * #interrupt-cells = <2>, so cell 0 is the RP1 interrupt number and cell 1
 * the trigger type.  Resolved at attach into rp1_int_eth; the constant is
 * the fallback.
 */
#define RP1_INT_ETH          6      /* fallback; see rp1_int_eth */

/* Where the GEM lives in the device trees this board is known to publish. */
static const char * const bcm2712_pcie_gem_paths[] = {
	"/axi/pcie@1000120000/rp1/ethernet@100000",
	"/soc/rp1/ethernet@100000",
	NULL
};

/* RP1 MSI-X vector for the GEM, from the device tree where available. */
static u_int rp1_int_eth = RP1_INT_ETH;

struct bcm2712_pcie_softc {
	device_t	 dev;
	struct resource	*irq_res;	/* SYS_RES_IRQ    rid 0 */
	void		*intr_cookie;
	bus_space_tag_t	 mac_bst;	/* GEM MAC */
	bus_space_handle_t mac_bsh;
	int		 mac_mapped;	/* by bus_space_map */
	bus_addr_t	 mac_phys;
};

/*
 * Module-level callback storage for rp1_eth's interrupt filter.
 *
 * These are intentionally NOT in bcm2712_pcie_softc.  The rp1_eth module
 * is often loaded from the boot loader and calls
 * bcm2712_pcie_register_rp1_intr() before bcm2712_pcie0 has probed/attached.
 * By storing the callback here, the registration succeeds at any time, and
 * the interrupt filter picks it up as soon as bcm2712_pcie0 hooks the GIC
 * line.
 *
 * Ordering contract (both store and load use rel/acq barriers):
 *   register:   store arg first, then filter (filter == NULL ⇒ arg ignored)
 *   deregister: clear filter first, then arg (filter == NULL ⇒ arg never read)
 */
static volatile uintptr_t g_rp1_filter;	/* atomic: driver_filter_t * */
static volatile uintptr_t g_rp1_arg;	/* atomic: void * */

/*
 * KPI: rp1_eth calls this to register its GEM interrupt filter.
 * Safe to call before or after bcm2712_pcie0 attaches.
 */
void
bcm2712_pcie_register_rp1_intr(driver_filter_t *filter, void *arg)
{
	/* Store arg before filter so the ISR never sees a stale arg. */
	atomic_store_rel_ptr(&g_rp1_arg, (uintptr_t)arg);
	atomic_store_rel_ptr(&g_rp1_filter, (uintptr_t)filter);
}

void
bcm2712_pcie_deregister_rp1_intr(void)
{
	/* Clear filter before arg so the ISR never fires with a stale arg. */
	atomic_store_rel_ptr(&g_rp1_filter, (uintptr_t)NULL);
	atomic_store_rel_ptr(&g_rp1_arg, (uintptr_t)NULL);
}

/*
 * Interrupt filter: called at interrupt level, no sleeping.
 * Read GEM INT_STATUS directly (the MAC resource is mapped at attach).
 * If GEM bits are set, dispatch to rp1_eth's filter.
 * Return FILTER_STRAY if GEM is not the source.
 *
 * The vector is acknowledged by rp1pci, RP1's interrupt controller, after
 * the filter has run.
 */
static int
bcm2712_pcie_filter(void *arg)
{
	struct bcm2712_pcie_softc *sc = arg;
	driver_filter_t *filter;
	void *filter_arg;
	uint32_t istat;

	istat = bus_space_read_4(sc->mac_bst, sc->mac_bsh, CGEM_INT_STATUS);
	if ((istat & CGEM_INT_ANY) == 0)
		return (FILTER_STRAY);

	filter = (driver_filter_t *)atomic_load_acq_ptr(&g_rp1_filter);
	if (filter == NULL)
		return (FILTER_STRAY);
	filter_arg = (void *)atomic_load_acq_ptr(&g_rp1_arg);

	return (filter(filter_arg));
}

/*
 * Is this board's device tree describing an RP1 GEM?  Used as the presence
 * test; the registers themselves are reached by physical address.
 */
static phandle_t
bcm2712_pcie_find_gem_node(void)
{
	phandle_t node;
	int i;

	for (i = 0; bcm2712_pcie_gem_paths[i] != NULL; i++) {
		node = OF_finddevice(bcm2712_pcie_gem_paths[i]);
		if (node != -1 &&
		    ofw_bus_node_is_compatible(node, "raspberrypi,rp1-gem"))
			return (node);
	}
	return (-1);
}

/*
 * Resolve the GEM's RP1 interrupt number from its interrupts property.
 */
static void
bcm2712_pcie_resolve_int_eth(device_t dev)
{
	phandle_t gem;
	pcell_t cells[2];
	int len;

	gem = bcm2712_pcie_find_gem_node();
	if (gem == -1)
		return;
	len = OF_getencprop(gem, "interrupts", cells, sizeof(cells));
	if (len < (int)sizeof(cells[0])) {
		device_printf(dev, "no interrupts property on the GEM node, "
		    "using RP1 vector %d\n", RP1_INT_ETH);
		return;
	}
	rp1_int_eth = cells[0];
	if (rp1_int_eth != RP1_INT_ETH)
		device_printf(dev, "RP1 GEM vector %u from FDT (built-in "
		    "default is %d)\n", rp1_int_eth, RP1_INT_ETH);
}

/* Called by rp1pci, after it has published BAR1. */
static void
bcm2712_pcie_identify(driver_t *driver, device_t parent)
{
	if (bcm2712_pcie_find_gem_node() == -1)
		return;
	if (device_find_child(parent, "bcm2712_pcie", -1) != NULL)
		return;
	if (BUS_ADD_CHILD(parent, 0, "bcm2712_pcie", -1) == NULL)
		device_printf(parent,
		    "bcm2712_pcie: BUS_ADD_CHILD failed\n");
}

static int
bcm2712_pcie_probe(device_t dev)
{
	if (bcm2712_pcie_find_gem_node() == -1)
		return (ENXIO);
	device_set_desc(dev, "BCM2712 PCIe2/RP1 GEM interrupt router");
	return (BUS_PROBE_DEFAULT);
}

/*
 * Map the GEM's own interrupt, as its node names it, against its interrupt
 * parent: the rp1 node, whose controller is rp1pci.  Returns 0 on failure.
 */
static u_int
bcm2712_pcie_map_gem_irq(device_t dev)
{
	phandle_t gem, iparent;
	pcell_t cells[2];
	int len;

	gem = bcm2712_pcie_find_gem_node();
	if (gem == -1)
		return (0);
	iparent = ofw_bus_find_iparent(gem);
	len = OF_getencprop(gem, "interrupts", cells, sizeof(cells));
	if (iparent == 0 || len != (int)sizeof(cells)) {
		device_printf(dev, "the GEM node has no two-cell interrupt "
		    "with a parent\n");
		return (0);
	}
	device_printf(dev, "GEM interrupt <%u %u> on the rp1 interrupt "
	    "controller\n", cells[0], cells[1]);
	return (ofw_bus_map_intr(dev, iparent, 2, cells));
}

/*
 * Map the GEM MAC window.  It is inside BAR1, which rp1pci owns, so it is
 * mapped directly by address.
 */
static int
bcm2712_pcie_map_regs(device_t dev, struct bcm2712_pcie_softc *sc)
{
	bus_addr_t bar_pa;

	if (!bcm2712_rp1_bar(&bar_pa, NULL)) {
		device_printf(dev, "RP1's BAR1 has not been published\n");
		return (ENXIO);
	}
	sc->mac_phys = bar_pa + GEM_MAC_OFFSET;
	if (!bcm2712_fdt_rp1(bcm2712_pcie_gem_paths, "raspberrypi,rp1-gem", 0,
	    &sc->mac_phys, NULL))
		device_printf(dev, "GEM reg not resolvable from FDT, "
		    "using BAR1 + %#x\n", GEM_MAC_OFFSET);
	sc->mac_bst = bus_get_bus_tag(dev);
	if (bus_space_map(sc->mac_bst, sc->mac_phys, GEM_MAC_SIZE, 0,
	    &sc->mac_bsh) != 0) {
		device_printf(dev, "cannot map GEM MAC registers at %#jx\n",
		    (uintmax_t)sc->mac_phys);
		return (ENXIO);
	}
	sc->mac_mapped = 1;
	return (0);
}

static void
bcm2712_pcie_unmap_regs(device_t dev, struct bcm2712_pcie_softc *sc)
{

	if (sc->mac_mapped) {
		bus_space_unmap(sc->mac_bst, sc->mac_bsh, GEM_MAC_SIZE);
		sc->mac_mapped = 0;
	}
}

static int
bcm2712_pcie_attach(device_t dev)
{
	struct bcm2712_pcie_softc *sc = device_get_softc(dev);
	int rid, error;
	u_int irq;

	sc->dev = dev;

	bcm2712_pcie_resolve_int_eth(dev);

	error = bcm2712_pcie_map_regs(dev, sc);
	if (error != 0)
		goto fail_mem;

	/* The GEM's own RP1 vector. */
	rid = 0;
	/*
	 * rp1pci keeps no resource list for its children, so the interrupt is
	 * allocated by number; pci and the host bridge pass it up to nexus,
	 * which resolves it through rp1pci's PIC.
	 */
	irq = bcm2712_pcie_map_gem_irq(dev);
	if (irq == 0) {
		device_printf(dev, "cannot map the GEM interrupt\n");
		error = ENXIO;
		goto fail_mem;
	}
	sc->irq_res = bus_alloc_resource(dev, SYS_RES_IRQ, &rid, irq, irq, 1,
	    RF_ACTIVE);
	if (sc->irq_res == NULL) {
		device_printf(dev, "cannot allocate interrupt\n");
		error = ENXIO;
		goto fail_mem;
	}

	error = bus_setup_intr(dev, sc->irq_res,
	    INTR_TYPE_NET | INTR_MPSAFE,
	    bcm2712_pcie_filter, NULL, sc, &sc->intr_cookie);
	if (error != 0) {
		device_printf(dev, "cannot set up interrupt: %d\n", error);
		goto fail_irq;
	}

	device_printf(dev, "GEM MAC mapped at %#jx, IRQ hooked (RP1 vector "
	    "%u)\n", (uintmax_t)sc->mac_phys, rp1_int_eth);
	return (0);

fail_irq:
	bus_release_resource(dev, SYS_RES_IRQ, 0, sc->irq_res);
fail_mem:
	bcm2712_pcie_unmap_regs(dev, sc);
	return (error);
}

static int
bcm2712_pcie_detach(device_t dev)
{
	struct bcm2712_pcie_softc *sc = device_get_softc(dev);

	bus_teardown_intr(dev, sc->irq_res, sc->intr_cookie);
	bus_release_resource(dev, SYS_RES_IRQ, 0, sc->irq_res);
	bcm2712_pcie_unmap_regs(dev, sc);
	return (0);
}

static device_method_t bcm2712_pcie_methods[] = {
	DEVMETHOD(device_identify,	bcm2712_pcie_identify),
	DEVMETHOD(device_probe,		bcm2712_pcie_probe),
	DEVMETHOD(device_attach,	bcm2712_pcie_attach),
	DEVMETHOD(device_detach,	bcm2712_pcie_detach),
	DEVMETHOD_END
};

static driver_t bcm2712_pcie_driver = {
	"bcm2712_pcie",
	bcm2712_pcie_methods,
	sizeof(struct bcm2712_pcie_softc),
};

/* RP1 is a PCI device behind bcm2712_pcib; attach below rp1pci. */
DRIVER_MODULE(bcm2712_pcie, rp1pci, bcm2712_pcie_driver, NULL, NULL);
MODULE_DEPEND(bcm2712_pcie, rp1, 1, 1, 1);
MODULE_VERSION(bcm2712_pcie, 1);
MODULE_DEPEND(bcm2712_pcie, bcm2712, 1, 1, 1);	/* bcm2712_fdt.h */
