# RapidBeagle external tree makefile.
# Includes any custom package .mk files. Empty in v1 — no custom packages yet.

include $(sort $(wildcard $(BR2_EXTERNAL_RAPIDBEAGLE_PATH)/package/*/*.mk))
