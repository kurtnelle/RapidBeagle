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
	USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN"

$(eval $(kernel-module))
$(eval $(generic-package))
