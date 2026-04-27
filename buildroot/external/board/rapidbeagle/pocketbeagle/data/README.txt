RapidBeagle data partition
==========================

This is the third partition on the SD card (FAT32). Edit files here on a
PC -- they're read by the device on next boot.

  config.txt  -- key=value config (WiFi, app binary name, etc).
  *           -- any other files (e.g. rapidbeagle-app binary).

The device mounts this partition READ-ONLY. To make changes, eject the SD,
edit on a PC, reinsert, and power-cycle the device.

The OS rootfs (partition 2) is mounted read-only via overlayfs after boot;
nothing is written to the SD card during normal operation.
