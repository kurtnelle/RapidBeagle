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

# Stable tag from https://github.com/aircrack-ng/rtl8812au/tags
RTL8812AU_VERSION = v5.13.6
RTL8812AU_SITE = $(call github,aircrack-ng,rtl8812au,$(RTL8812AU_VERSION))
RTL8812AU_LICENSE = GPL-2.0
RTL8812AU_LICENSE_FILES = LICENSE

# Build flags — disable platforms we're not on, force ARM for AM335x.
# The driver's Makefile is platform-conditional via these CONFIG_PLATFORM_* vars.
# For PocketBeagle 2 (aarch64), switch to CONFIG_PLATFORM_ARM_AARCH64=y.
RTL8812AU_MODULE_MAKE_OPTS = \
	CONFIG_PLATFORM_I386_PC=n \
	CONFIG_PLATFORM_ARM_AM335X=y \
	USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN"

$(eval $(kernel-module))
$(eval $(generic-package))
