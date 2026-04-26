################################################################################
#
# rtl8812au — out-of-tree driver for Realtek RTL8811AU / 8812AU / 8821AU /
# 8814AU USB WiFi chipsets (e.g., Edimax EW-7811UTC AC600).
#
# Mainline Linux 6.6 has rtw88 (PCI-E AC chips) and rtl8xxxu (older 8188CU/
# 8192CU N chips) but neither covers the USB-AC family. The aircrack-ng
# fork is the de-facto mainstream driver for these chips.
#
# Module name: 88XXau.ko
#
################################################################################

# morrownr/8812au-20210820 fork — much more aggressively tracks kernel API
# changes than aircrack-ng. The aircrack-ng v5.13.6 tag doesn't compile
# against Linux 6.6 (cfg80211_ch_switch_notify took an extra punct_bitmap
# arg in 6.5+ for WiFi 7 support).
#
# Pin to a known-good tag from morrownr; bump as needed when newer kernels
# break things again.
# morrownr's repo has no tags — pin to the current HEAD commit on main.
# Bump as needed when a kernel API change breaks the build again.
RTL8812AU_VERSION = 1be3d39079264fbc4763548ce9e9a26a5a9742ab
RTL8812AU_SITE = $(call github,morrownr,8812au-20210820,$(RTL8812AU_VERSION))
RTL8812AU_LICENSE = GPL-2.0
RTL8812AU_LICENSE_FILES = LICENSE

# Build flags. NOTE on the Makefile's CONFIG_PLATFORM_* options:
#
# Despite the name, CONFIG_PLATFORM_I386_PC is the "generic Linux" set of
# flags — it does NOT hardcode an i386 toolchain or arch. The other named
# platforms (TI_AM3517, ARM_RPI, etc.) hardcode CROSS_COMPILE and ARCH in
# ways that fight Buildroot's kernel-module infrastructure (which already
# sets ARCH=arm CROSS_COMPILE=arm-buildroot-...).
#
# So leave CONFIG_PLATFORM_I386_PC=y (the default) — Buildroot supplies
# the actual ARCH and CROSS_COMPILE correctly. We only add target CFLAGS.
#
# This works equally well for ARMv7 (PocketBeagle 1) and aarch64
# (PocketBeagle 2) — Buildroot's kernel-module build handles arch.
#
# CONFIG_RTL8812AU=m is the actual obj-m switch the Makefile checks at
# kernel-build time:
#     obj-$(CONFIG_RTL8812AU) := $(MODULE_NAME).o
# Without this, obj-m is empty, no .c files compile, only MODPOST runs,
# and no .ko file is produced. Standard `make` for this driver always
# passes CONFIG_RTL8812AU=m on the command line.
RTL8812AU_MODULE_MAKE_OPTS = \
	CONFIG_RTL8812AU=m \
	CONFIG_RTL8821A=y \
	CONFIG_RTL8814A=y \
	USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN"
# CONFIG_RTL8821A=y is REQUIRED for the Edimax EW-7811UTC AC600 (chipset
# RTL8811AU — handled by the RTL8821 codepath). The Makefile defaults this
# to 'n' which strips all RTL8821 USB device entries from the compiled
# module's device table, so MODULE_DEVICE_TABLE never sees them and the
# kernel won't auto-bind the dongle.
# CONFIG_RTL8814A=y for free coverage of AC1900 quad-band dongles.

# Fix for an internal symbol rename inconsistency in morrownr's main HEAD:
# _FW_UNDER_SURVEY was globally renamed to WIFI_UNDER_SURVEY but two call
# sites in rtw_xmit.c still use the old name, causing the build to fail
# with "undeclared identifier" against Linux 6.6. Until upstream fixes it
# we sed it ourselves right after the source is extracted.
define RTL8812AU_FIX_FW_UNDER_SURVEY_RENAME
	$(SED) 's/_FW_UNDER_SURVEY/WIFI_UNDER_SURVEY/g' $(@D)/core/rtw_xmit.c
endef
RTL8812AU_POST_EXTRACT_HOOKS += RTL8812AU_FIX_FW_UNDER_SURVEY_RENAME

# Add Edimax EW-7811UTC AC600 (USB ID 7392:a812) — RTL8811AU chipset, classifies
# as RTL8821 in this driver. The morrownr fork's USB ID table covers most
# Edimax variants (0xA811, 0xA822, 0xA834) but misses 0xA812 specifically.
# Inject the missing line right after the existing 0xA811 entry.
define RTL8812AU_ADD_EDIMAX_AC600_ID
	$(SED) '/0x7392, 0xA811.*Edimax/a\	{USB_DEVICE(0x7392, 0xA812), .driver_info = RTL8821}, /* Edimax EW-7811UTC AC600 */' $(@D)/os_dep/linux/usb_intf.c
endef
RTL8812AU_POST_EXTRACT_HOOKS += RTL8812AU_ADD_EDIMAX_AC600_ID

$(eval $(kernel-module))
$(eval $(generic-package))
