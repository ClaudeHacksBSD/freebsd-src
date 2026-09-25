/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Jeremy McMillan
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/*
 * initrd.c -- adopt the image the VPU firmware loaded with config.txt
 * "initramfs" as the loader's memory disk, and optionally as the kernel's
 * root.
 *
 * The firmware reads the file named by
 *
 *	initramfs <file> <address>
 *
 * from the FAT boot partition into RAM at <address> and records where it put
 * it in /chosen, the way it does for Linux:
 *
 *	linux,initrd-start = <start>;	(one or two cells)
 *	linux,initrd-end   = <end>;	(exclusive)
 *
 * The image is a bare UFS filesystem made by makefs.  Registering it with
 * md_register() from stand/common/md.c makes it "md0:", so every path the
 * loader opens -- /boot/loader.conf, /boot/kernel/kernel, modules -- comes
 * out of it with no storage driver at all.  That is what lets one release
 * image boot without an SD card driver in the loader, and it replaces the
 * embedded-in-.data memory disk the bring-up loader used, which capped the
 * image at the space between the loader and the device tree.
 *
 * Two ways the kernel can then find its root:
 *
 *   rpiboot_initrd_root="YES"	the whole image is copied into the staging
 *				window as an "mfs_root" module, so the kernel's
 *				md(4) attaches it as md0 and
 *				vfs.root.mountfrom="ufs:/dev/md0" mounts it.
 *				This is the live system and installer.
 *
 *   rpiboot_initrd_root="NO"	the image only carried the kernel; root comes
 *	(default)		from wherever vfs.root.mountfrom says, which on
 *				an installed system is the SD card.
 *
 * The copy in the first case is deliberate.  The arm64 kernel reserves the
 * physical span of the kernel and its modules (up to kernend) and nothing
 * else, so a region the firmware placed elsewhere would be treated as free
 * memory as soon as the VM system started.  Copying it behind the kernel
 * puts it inside that reserved span, where md(4) expects a preloaded image
 * to be.
 */

#include <stand.h>
#include <sys/param.h>

#include <libfdt.h>

#include "bootstrap.h"
#include "modinfo.h"
#include "librpiboot.h"

#define	RPI_INITRD_BLKSZ	512

static uint64_t	initrd_pa;
static uint64_t	initrd_len;

static int
initrd_getcell(const void *fdt, int node, const char *name, uint64_t *valp)
{
	const void *prop;
	int len;

	prop = fdt_getprop(fdt, node, name, &len);
	if (prop == NULL)
		return (ENOENT);

	switch (len) {
	case sizeof(uint32_t):
		*valp = fdt32_to_cpu(*(const fdt32_t *)prop);
		return (0);
	case sizeof(uint64_t):
		*valp = fdt64_to_cpu(*(const fdt64_t *)prop);
		return (0);
	default:
		printf("initrd: %s has unexpected length %d\n", name, len);
		return (EINVAL);
	}
}

/*
 * Find the image and register it as a memory disk.  Called from main()
 * before the device switch is probed, and reads the firmware's tree directly
 * through libfdt: fdt_platform_load_dtb() is not run until something needs
 * the tree for the kernel, which is too late to decide what currdev is.
 *
 * Every rejection says why.  A missing initrd is not an error in itself --
 * a loader with an embedded image does not need one -- but an initrd that
 * is present and unusable always is, and the reason is the only clue the
 * person at the serial console will have.
 */
int
rpi_initrd_probe(const void *fdt, uint64_t reserved_end)
{
	uint64_t start, end, len;
	int node;

	if (fdt == NULL || fdt_check_header(fdt) != 0)
		return (ENOENT);

	node = fdt_path_offset(fdt, "/chosen");
	if (node < 0)
		return (ENOENT);

	if (initrd_getcell(fdt, node, "linux,initrd-start", &start) != 0 ||
	    initrd_getcell(fdt, node, "linux,initrd-end", &end) != 0)
		return (ENOENT);

	if (end <= start) {
		printf("initrd: empty or inverted range 0x%lx..0x%lx; "
		    "ignoring it\n", (unsigned long)start, (unsigned long)end);
		return (EINVAL);
	}

	/*
	 * Anything below the end of what the loader itself occupies --
	 * image, device tree, heap and staging window -- is going to be
	 * overwritten, either by our own allocations or by the kernel being
	 * assembled.  The initramfs address in config.txt has to clear it.
	 */
	if (start < reserved_end) {
		printf("initrd: image at 0x%lx overlaps the loader's own "
		    "memory (ends 0x%lx);\n"
		    "        move \"initramfs\" in config.txt to 0x%lx or "
		    "above.\n", (unsigned long)start,
		    (unsigned long)reserved_end, (unsigned long)reserved_end);
		return (EINVAL);
	}

	/*
	 * md_register() insists on whole 512-byte blocks.  makefs images
	 * always are; anything else is either not a filesystem or was
	 * truncated on the way, and a filesystem whose tail is missing is
	 * worse than none.
	 */
	len = end - start;
	if (len % RPI_INITRD_BLKSZ != 0) {
		printf("initrd: size %lu is not a multiple of %d; "
		    "not a makefs image?\n", (unsigned long)len,
		    RPI_INITRD_BLKSZ);
		return (EINVAL);
	}

	if (md_register((void *)(uintptr_t)start, len, 0) < 0) {
		printf("initrd: md_register failed: %s\n", strerror(errno));
		return (errno);
	}

	initrd_pa = start;
	initrd_len = len;
	printf("   Initrd:          0x%lx + %lu KiB (from /chosen)\n",
	    (unsigned long)start, (unsigned long)(len / 1024));
	return (0);
}

bool
rpi_initrd_present(void)
{
	return (initrd_len != 0);
}

/*
 * Hand the initrd to the kernel as its root, if asked.  Called from the exec
 * path once every module is loaded, so nothing is placed after it and the
 * copy lands at the very end of the staged set, inside kernend.
 */
int
rpi_initrd_stage_root(void)
{
	struct preloaded_file *fp;
	vm_offset_t end;
	const char *v;

	v = getenv("rpiboot_initrd_root");
	if (v == NULL || (strcasecmp(v, "YES") != 0 && strcmp(v, "1") != 0))
		return (0);

	if (initrd_len == 0) {
		printf("rpiboot_initrd_root is set but there is no initrd; "
		    "the kernel will look for its root elsewhere.\n");
		return (0);
	}

	/* An explicit mfsroot_load in loader.conf wins; do not add two. */
	if (file_findfile(NULL, "mfs_root") != NULL ||
	    file_findfile(NULL, "md_image") != NULL) {
		printf("An md root image is already loaded; not adding the "
		    "initrd as a second one.\n");
		return (0);
	}

	/*
	 * file_addbuf() does not check what arch_copyin returns, so a
	 * staging overflow would leave a module whose metadata claims bytes
	 * that were never written.  Check the fit first, from the same end
	 * address file_addbuf() will use.
	 */
	end = 0;
	for (fp = file_findfile(NULL, NULL); fp != NULL; fp = fp->f_next)
		if (fp->f_addr + fp->f_size > end)
			end = fp->f_addr + fp->f_size;
	if (!rpi_stage_fits(md_align(end), initrd_len)) {
		printf("The initrd (%lu KiB) does not fit in the staging "
		    "window behind the kernel.\n",
		    (unsigned long)(initrd_len / 1024));
		return (ENOMEM);
	}

	printf("Staging initrd as the kernel's root (%lu KiB)...\n",
	    (unsigned long)(initrd_len / 1024));
	if (file_addbuf("/initrd", "mfs_root", initrd_len,
	    (void *)(uintptr_t)initrd_pa) != 0) {
		printf("Could not stage the initrd: %s\n", command_errbuf);
		return (ENOMEM);
	}

	return (0);
}
