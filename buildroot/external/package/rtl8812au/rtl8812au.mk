################################################################################
#
# rtl8812au — Realtek RTL8811AU / 8821AU USB WiFi driver
#
# Driver journey:
#   - aircrack-ng/rtl8812au v5.13.6: full chipset coverage but doesn't compile
#     against Linux 6.6 (cfg80211 + REGULATORY_IGNORE_STALE_KICKOFF API
#     changes). Even with our patches it produced wlan0 but the chip MCU
#     races _FWFreeToGo8812: WINTINI_RDY never flips → FW download "succeeds"
#     (checksum OK) but the chip never goes live. Confirmed dead-end on
#     mainline 6.4+ + AM335x MUSB host.
#
#   - morrownr/8812au-20210820: stripped RTL8821A source — won't work for
#     our Edimax AC600 (RTL8811AU chipset → handled via 8821A codepath).
#
#   - morrownr/8821au-20210708 (CURRENT): dedicated 8811AU/8821AU repo,
#     active 2024+, distinct HAL init refactor → real chance of fixing
#     the post-FW-download MCU readiness timeout.
#
# Module name produced: 8821au.ko
# Load with: modprobe 8821au
#
################################################################################

# morrownr/8821au-20210708 has no tags — pin to the current main HEAD.
# Bump as needed when newer kernels break things again.
RTL8812AU_VERSION = 0afd9bac2c6a53a4717df804631b5b2268c0bd24
RTL8812AU_SITE = $(call github,morrownr,8821au-20210708,$(RTL8812AU_VERSION))
RTL8812AU_LICENSE = GPL-2.0
RTL8812AU_LICENSE_FILES = LICENSE

# Same Makefile-gating pattern as morrownr/8812au but the obj-m trigger is
# CONFIG_RTL8821AU=m (note: 8821AU, not 8812AU — this is a different repo
# focused on the 8811AU/8821AU chipsets). Without it, no .c files compile;
# only MODPOST runs and no .ko is produced.
# CONFIG_PLATFORM_I386_PC is the "generic Linux" path; Buildroot supplies
# the actual cross-compiler so leaving it at default is correct.
RTL8812AU_MODULE_MAKE_OPTS = \
	CONFIG_RTL8821AU=m \
	USER_EXTRA_CFLAGS="-DCONFIG_LITTLE_ENDIAN"

$(eval $(kernel-module))
$(eval $(generic-package))
