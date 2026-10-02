--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Copyright (c) 2026 Jeremy McMillan
--
-- /boot/lua/local.lua on a Raspberry Pi 5 card that kept its installer.
--
-- The installer's post-install step writes this file, with @INSTALLER_ROOT@
-- replaced, when the user keeps the installer on the card.  loader.lua
-- includes local.lua if it exists, and menu.lua(8) names
-- menu.welcome.all_entries.vendor as the entry for a local addition.
--
-- The entry boots the kernel the menu would boot anyway, with the
-- installer's partition as root instead of the installed system.  Delete
-- this file to remove the entry.
--

local core = require("core")
local color = require("color")
local menu = require("menu")

menu.welcome.all_entries.vendor = {
	entry_type = core.MENU_ENTRY,
	name = "FreeBSD " .. color.highlight("I") .. "nstaller",
	func = function()
		loader.setenv("vfs.root.mountfrom", "@INSTALLER_ROOT@")
		core.setSingleUser(false)
		core.boot()
	end,
	alias = {"i", "I"},
}
