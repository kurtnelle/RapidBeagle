################################################################################
#
# rtl8812au — out-of-tree driver for Realtek RTL8811AU / 8812AU / 8821AU
# USB WiFi chipsets (e.g., Edimax EW-7811UTC AC600).
#
# Mainline Linux 6.6 has rtw88 (PCI-E AC chips) and rtl8xxxu (older 8188CU/
# 8192CU N chips) but neither covers the USB-AC family. The aircrack-ng
# fork is the most complete chipset-coverage option.
#
# Module name: 88XXau.ko
#
# We use the aircrack-ng fork because it's the only one that ships
# RTL8821A source files needed for the RTL8811AU chipset (which the
# Edimax AC600 uses). morrownr's fork is 8812AU-only — RTL8821A code
# was stripped. v5.13.6 is the latest tagged release; it doesn't
# compile clean against Linux 6.6 (cfg80211 API changes), so we patch
# those two call sites via POST_EXTRACT hook.
#
################################################################################

# Stable tag from https://github.com/aircrack-ng/rtl8812au/tags
RTL8812AU_VERSION = v5.13.6
RTL8812AU_SITE = $(call github,aircrack-ng,rtl8812au,$(RTL8812AU_VERSION))
RTL8812AU_LICENSE = GPL-2.0
RTL8812AU_LICENSE_FILES = LICENSE

RTL8812AU_MODULE_MAKE_OPTS = \
	CONFIG_RTL8812AU=m \
	USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN"
# Note on CONFIG_PLATFORM_*:
#   The Makefile's CONFIG_PLATFORM_I386_PC is misleadingly named — it's the
#   "generic Linux" path; doesn't hardcode an x86 toolchain. Buildroot
#   already supplies ARCH/CROSS_COMPILE via -C $(LINUX_DIR), so we leave
#   the default I386_PC=y. Setting alternative platform names breaks the
#   build because they hardcode different toolchains.
#
# Note on chipset CONFIGs:
#   The Makefile defaults CONFIG_RTL8812A=y, CONFIG_RTL8821A=y in this
#   fork — both required for the Edimax AC600 (RTL8811AU → RTL8821A
#   codepath). Don't override these; the morrownr fork stripped the 8821A
#   source files, but aircrack-ng has them.

# ── Patch 1: Linux 6.5+ added `punct_bitmap` to cfg80211_ch_switch_notify
# and cfg80211_ch_switch_started_notify (for 802.11be/WiFi 7). v5.13.6's
# call sites don't pass it. Inject a `, 0` literal at the end of each
# call. Two specific call sites in os_dep/linux/ioctl_cfg80211.c.
define RTL8812AU_FIX_CFG80211_PUNCT_BITMAP
	$(SED) 's|cfg80211_ch_switch_started_notify(adapter->pnetdev, &chdef, 0, 0, false);|cfg80211_ch_switch_started_notify(adapter->pnetdev, \&chdef, 0, 0, false, 0);|' \
		$(@D)/os_dep/linux/ioctl_cfg80211.c
	$(SED) 's|cfg80211_ch_switch_notify(adapter->pnetdev, &chdef, 0);|cfg80211_ch_switch_notify(adapter->pnetdev, \&chdef, 0, 0);|' \
		$(@D)/os_dep/linux/ioctl_cfg80211.c
endef
RTL8812AU_POST_EXTRACT_HOOKS += RTL8812AU_FIX_CFG80211_PUNCT_BITMAP

# ── Patch 2: Add Edimax EW-7811UTC AC600 (USB ID 7392:a812) to the device
# table. aircrack-ng v5.13.6 covers other Edimax variants (0xA811, 0xA822,
# 0xA834) but misses 0xA812 specifically. Same RTL8811AU chipset → handled
# as RTL8821 family by this driver.
define RTL8812AU_ADD_EDIMAX_AC600_ID
	grep -q '0x7392, 0xA812' $(@D)/os_dep/linux/usb_intf.c || \
		$(SED) '/0x7392, 0xA811.*Edimax/a\	{USB_DEVICE(0x7392, 0xA812), .driver_info = RTL8821}, /* Edimax EW-7811UTC AC600 */' $(@D)/os_dep/linux/usb_intf.c
endef
RTL8812AU_POST_EXTRACT_HOOKS += RTL8812AU_ADD_EDIMAX_AC600_ID

$(eval $(kernel-module))
$(eval $(generic-package))
