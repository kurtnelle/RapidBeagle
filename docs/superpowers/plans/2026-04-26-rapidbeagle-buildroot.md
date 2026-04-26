# RapidBeagle Buildroot Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Buildroot external tree under `buildroot/` in the existing RapidBeagle repo that produces a fast-booting (<10s power-on to NativeAOT app) SD card image for PocketBeagle (AM335x).

**Architecture:** Buildroot external tree with one defconfig (`rapidbeagle_pb_defconfig`), a kernel config fragment layered on `omap2plus_defconfig`, BusyBox init with three numbered scripts (network/heartbeat/app-launcher), `genimage` for SD layout, and two wrapper scripts (build + flash). All configuration lives in `buildroot/external/`; Buildroot itself is cloned separately. No code is "executed" during plan implementation — the plan produces config files. The first actual build happens manually in WSL2 after the plan completes.

**Tech Stack:** Buildroot 2024.02.x LTS (or newer stable), Linux 6.6.x LTS kernel, U-Boot, BusyBox, glibc, OpenSSH, wpa_supplicant, genimage, shellcheck (validation), bash 5+

> **Testing approach for this plan:** Buildroot configs have no traditional unit tests. Each task validates files via `shellcheck` (for shell scripts), `bash -n` (syntax), `grep` (content presence), or visual inspection (for config files Buildroot itself will validate at build time). The ultimate test is a manual WSL2 build (Task 16) and on-device boot (out of plan scope — performed by the user after merge).

---

## File Structure

| File | Responsibility |
|---|---|
| `buildroot/external/Config.in` | Buildroot Kconfig hook — points at custom packages (empty for v1) |
| `buildroot/external/external.desc` | External tree name + version metadata |
| `buildroot/external/external.mk` | Makefile fragment for custom packages (empty for v1) |
| `buildroot/external/configs/rapidbeagle_pb_defconfig` | The single defconfig — picks toolchain, kernel, U-Boot, packages, init |
| `buildroot/external/board/rapidbeagle/pocketbeagle/linux-fragment.config` | Kernel config diff applied on top of `omap2plus_defconfig` |
| `buildroot/external/board/rapidbeagle/pocketbeagle/busybox-inittab` | BusyBox `/etc/inittab` |
| `buildroot/external/board/rapidbeagle/pocketbeagle/interfaces` | `/etc/network/interfaces` (usb0 static, eth0 DHCP if present) |
| `buildroot/external/board/rapidbeagle/pocketbeagle/uEnv.txt` | U-Boot environment (silent boot, kernel cmdline with `quiet loglevel=3`) |
| `buildroot/external/board/rapidbeagle/pocketbeagle/genimage.cfg` | SD card partition layout |
| `buildroot/external/board/rapidbeagle/pocketbeagle/post-build.sh` | Runs after rootfs assembly — installs SSH key, hardens sshd |
| `buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh` | Runs after kernel/U-Boot/rootfs built — calls genimage to make sdcard.img |
| `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S98-pb-heartbeat` | USR0 LED heartbeat script |
| `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S99-app-launcher` | Launches `/opt/app/rapidbeagle-app` if present |
| `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/opt/app/.gitkeep` | Reserves the app deploy directory |
| `buildroot/scripts/build.sh` | One-command build wrapper |
| `buildroot/scripts/flash-sdcard.sh` | Interactive SD flasher with safety checks |
| `buildroot/README.md` | Build & flash instructions |
| `README.md` (root) | Updated to describe both approaches (Debian script + Buildroot) |

---

## Task 1: Scaffold the Buildroot External Tree

**Files:**
- Create: `buildroot/external/external.desc`
- Create: `buildroot/external/external.mk`
- Create: `buildroot/external/Config.in`
- Create: `buildroot/external/package/.gitkeep`
- Create: `buildroot/external/configs/.gitkeep`
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/.gitkeep`

- [ ] **Step 1.1: Create `buildroot/external/external.desc`**

```
name: RAPIDBEAGLE
desc: RapidBeagle Buildroot external tree for PocketBeagle fast-boot image
```

- [ ] **Step 1.2: Create `buildroot/external/external.mk`**

```makefile
# RapidBeagle external tree makefile.
# Includes any custom package .mk files. Empty in v1 — no custom packages yet.

include $(sort $(wildcard $(BR2_EXTERNAL_RAPIDBEAGLE_PATH)/package/*/*.mk))
```

- [ ] **Step 1.3: Create `buildroot/external/Config.in`**

Buildroot tolerates an empty/comment-only Config.in — that's what we want for v1 since we have no custom packages yet.

```
# RapidBeagle external tree Kconfig hooks.
# No custom packages in v1 — this file is intentionally empty other than this comment.
# Future custom packages will add: source "$BR2_EXTERNAL_RAPIDBEAGLE_PATH/package/<name>/Config.in"
```

- [ ] **Step 1.4: Create directory placeholders**

```bash
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/external/package"
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/external/configs"
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle"
touch "I:/Source/repos/RapidBeagle/buildroot/external/package/.gitkeep"
touch "I:/Source/repos/RapidBeagle/buildroot/external/configs/.gitkeep"
touch "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/.gitkeep"
```

- [ ] **Step 1.5: Verify file presence**

```bash
ls -la "I:/Source/repos/RapidBeagle/buildroot/external/"
cat "I:/Source/repos/RapidBeagle/buildroot/external/external.desc"
cat "I:/Source/repos/RapidBeagle/buildroot/external/external.mk"
```
Expected: `external.desc`, `external.mk`, `Config.in`, and three subdirectories present.

- [ ] **Step 1.6: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/
git commit -m "feat(buildroot): scaffold external tree (Config.in, external.desc, external.mk)"
```

---

## Task 2: Buildroot defconfig — `rapidbeagle_pb_defconfig`

**Files:**
- Create: `buildroot/external/configs/rapidbeagle_pb_defconfig`

- [ ] **Step 2.1: Create the defconfig**

```
# rapidbeagle_pb_defconfig
# Buildroot defconfig for PocketBeagle (AM335x) fast-boot image
# Goal: <10s power-on to NativeAOT dotnet app

# ── Architecture ─────────────────────────────────────────────────────────────
BR2_arm=y
BR2_cortex_a8=y
BR2_ARM_FPU_VFPV3=y
BR2_ARM_INSTRUCTIONS_THUMB2=y

# ── Toolchain ────────────────────────────────────────────────────────────────
# Use Buildroot's internal toolchain with glibc (NativeAOT compatibility).
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y

# ── Bootloader: U-Boot ───────────────────────────────────────────────────────
BR2_TARGET_UBOOT=y
BR2_TARGET_UBOOT_BUILD_SYSTEM_KCONFIG=y
BR2_TARGET_UBOOT_BOARD_DEFCONFIG="am335x_evm"
BR2_TARGET_UBOOT_FORMAT_IMG=y
BR2_TARGET_UBOOT_SPL=y
BR2_TARGET_UBOOT_SPL_NAME="MLO"
BR2_TARGET_UBOOT_NEEDS_DTC=y

# ── Kernel ───────────────────────────────────────────────────────────────────
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="6.6.30"
BR2_LINUX_KERNEL_DEFCONFIG="omap2plus"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$(BR2_EXTERNAL_RAPIDBEAGLE_PATH)/board/rapidbeagle/pocketbeagle/linux-fragment.config"
BR2_LINUX_KERNEL_DTS_SUPPORT=y
BR2_LINUX_KERNEL_INTREE_DTS_NAME="am335x-pocketbeagle"
BR2_LINUX_KERNEL_ZIMAGE=y
BR2_LINUX_KERNEL_NEEDS_HOST_OPENSSL=y

# ── Init system ──────────────────────────────────────────────────────────────
BR2_INIT_BUSYBOX=y

# ── Filesystem ───────────────────────────────────────────────────────────────
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="240M"
BR2_TARGET_ROOTFS_TAR=y

# ── /dev management: devtmpfs (mounted by kernel, BusyBox manages it) ───────
BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_DEVTMPFS=y

# ── System config ────────────────────────────────────────────────────────────
BR2_TARGET_GENERIC_HOSTNAME="rapidbeagle"
BR2_TARGET_GENERIC_ISSUE="Welcome to RapidBeagle"
BR2_TARGET_GENERIC_GETTY=y
BR2_TARGET_GENERIC_GETTY_PORT="ttyS0"
BR2_TARGET_GENERIC_GETTY_BAUDRATE_115200=y
BR2_SYSTEM_BIN_SH_BASH=n
BR2_SYSTEM_DEFAULT_PATH="/usr/bin:/usr/sbin:/bin:/sbin"
BR2_TARGET_GENERIC_ROOT_PASSWD=""

# ── Rootfs overlay (our custom files) ────────────────────────────────────────
BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_RAPIDBEAGLE_PATH)/board/rapidbeagle/pocketbeagle/rootfs-overlay"

# ── Custom inittab and interfaces (override BusyBox defaults) ───────────────
BR2_PACKAGE_BUSYBOX_INDIVIDUAL_BINARIES=n
BR2_PACKAGE_BUSYBOX_SHOW_OTHERS=n
BR2_PACKAGE_BUSYBOX=y

# ── Post-build / post-image hooks ────────────────────────────────────────────
BR2_ROOTFS_POST_BUILD_SCRIPT="$(BR2_EXTERNAL_RAPIDBEAGLE_PATH)/board/rapidbeagle/pocketbeagle/post-build.sh"
BR2_ROOTFS_POST_IMAGE_SCRIPT="$(BR2_EXTERNAL_RAPIDBEAGLE_PATH)/board/rapidbeagle/pocketbeagle/post-image.sh"

# ── genimage host package (for SD image assembly) ───────────────────────────
BR2_PACKAGE_HOST_GENIMAGE=y

# ── Userspace packages ───────────────────────────────────────────────────────
# OpenSSH for dev access
BR2_PACKAGE_OPENSSH=y
BR2_PACKAGE_OPENSSH_KEY_UTILS=y
BR2_PACKAGE_OPENSSH_SERVER=y
BR2_PACKAGE_OPENSSH_CLIENT=y

# wpa_supplicant for WiFi (dotnet app drives via control socket)
BR2_PACKAGE_WPA_SUPPLICANT=y
BR2_PACKAGE_WPA_SUPPLICANT_NL80211=y
BR2_PACKAGE_WPA_SUPPLICANT_CTRL_IFACE=y
BR2_PACKAGE_WPA_SUPPLICANT_CLI=y

# Wireless tools
BR2_PACKAGE_IW=y

# CA certificates for HTTPS calls from the app
BR2_PACKAGE_CA_CERTIFICATES=y

# Time zone data
BR2_PACKAGE_TZDATA=y
BR2_PACKAGE_TZDATA_ZONELIST="UTC America/Chicago Etc/UTC"

# Network ifupdown scripts (for /etc/network/interfaces support)
BR2_PACKAGE_IFUPDOWN_SCRIPTS=y

# Network basics
BR2_PACKAGE_NETBASE=y
BR2_PACKAGE_BUSYBOX_SHOW_OTHERS=n
```

- [ ] **Step 2.2: Verify content**

```bash
grep -c "^BR2_" "I:/Source/repos/RapidBeagle/buildroot/external/configs/rapidbeagle_pb_defconfig"
```
Expected: at least 30 lines starting with `BR2_`.

- [ ] **Step 2.3: Lint check (defconfig is plain key=value, no real lint, but check no Windows line endings)**

```bash
file "I:/Source/repos/RapidBeagle/buildroot/external/configs/rapidbeagle_pb_defconfig"
```
Expected: `ASCII text` — NOT `with CRLF line terminators`. (`.gitattributes` should keep it LF anyway.)

- [ ] **Step 2.4: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/configs/rapidbeagle_pb_defconfig
git commit -m "feat(buildroot): add rapidbeagle_pb_defconfig (toolchain, kernel, U-Boot, packages)"
```

---

## Task 3: Kernel Config Fragment

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/linux-fragment.config`

This fragment is layered on top of mainline `omap2plus_defconfig` by Buildroot. Only the diffs go here.

- [ ] **Step 3.1: Create the fragment**

```
# linux-fragment.config — RapidBeagle kernel diffs on omap2plus_defconfig
# Applied via BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES.
# Use `# CONFIG_FOO is not set` to disable, `CONFIG_FOO=y` to enable.

# ─── Disable: Bluetooth (no BT on RapidBeagle) ──────────────────────────────
# CONFIG_BT is not set
# CONFIG_BT_BREDR is not set
# CONFIG_BT_LE is not set

# ─── Disable: HDA + SoC audio (we use USB MIDI only) ────────────────────────
# CONFIG_SND_HDA_INTEL is not set
# CONFIG_SND_HDA_CODEC_GENERIC is not set
# CONFIG_SND_SOC is not set
# CONFIG_SND_SOC_TI is not set
# CONFIG_SND_SOC_AM33XX is not set

# ─── Enable: USB MIDI / ALSA core ───────────────────────────────────────────
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_USB=y
CONFIG_SND_USB_AUDIO=y
CONFIG_SND_RAWMIDI=y
CONFIG_SND_SEQUENCER=y
CONFIG_SND_SEQ_MIDI=y
CONFIG_SND_SEQ_MIDI_EVENT=y

# ─── Enable: USB WiFi drivers (common dongles) ──────────────────────────────
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_WLAN=y
CONFIG_WLAN_VENDOR_REALTEK=y
CONFIG_RTL8XXXU=y
CONFIG_WLAN_VENDOR_RALINK=y
CONFIG_RT2X00=y
CONFIG_RT2800USB=y
CONFIG_WLAN_VENDOR_MEDIATEK=y
CONFIG_MT7601U=y
CONFIG_WLAN_VENDOR_BROADCOM=y
CONFIG_BRCMFMAC=y
CONFIG_BRCMFMAC_USB=y
CONFIG_WLAN_VENDOR_ATH=y
CONFIG_ATH9K_HTC=y

# ─── Enable: Network bridge (for app future use) ────────────────────────────
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_VLAN_8021Q=y

# ─── Enable: USB gadget (RNDIS + ECM for usb0 dev access) ───────────────────
CONFIG_USB_GADGET=y
CONFIG_USB_LIBCOMPOSITE=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_RNDIS=y
CONFIG_USB_CONFIGFS_ECM=y
CONFIG_USB_CONFIGFS_NCM=y

# ─── Enable: LED class for USR0 heartbeat ────────────────────────────────────
CONFIG_NEW_LEDS=y
CONFIG_LEDS_CLASS=y
CONFIG_LEDS_GPIO=y
CONFIG_LEDS_TRIGGERS=y
CONFIG_LEDS_TRIGGER_HEARTBEAT=y
CONFIG_LEDS_TRIGGER_DEFAULT_ON=y

# ─── Enable: GPIO sysfs/cdev for app userspace access ───────────────────────
CONFIG_GPIOLIB=y
CONFIG_GPIO_SYSFS=y
CONFIG_GPIO_CDEV=y

# ─── Disable: Filesystems we don't need ─────────────────────────────────────
# CONFIG_BTRFS_FS is not set
# CONFIG_XFS_FS is not set
# CONFIG_NTFS_FS is not set
# CONFIG_F2FS_FS is not set
# CONFIG_REISERFS_FS is not set
# CONFIG_JFFS2_FS is not set

# ─── Disable: Heavy debug / tracing (boot speed) ────────────────────────────
# CONFIG_FTRACE is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_KGDB is not set
# CONFIG_AUDIT is not set
# CONFIG_AUDITSYSCALL is not set
# CONFIG_PERF_EVENTS is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_DEBUG_FS is not set

# ─── Disable: Other unused subsystems ───────────────────────────────────────
# CONFIG_CAN is not set
# CONFIG_NFC is not set
# CONFIG_RFKILL_INPUT is not set
# CONFIG_HAMRADIO is not set
# CONFIG_IRDA is not set
# CONFIG_WIMAX is not set

# ─── Required: ext4 for rootfs ──────────────────────────────────────────────
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_VFAT_FS=y
CONFIG_TMPFS=y
CONFIG_CONFIGFS_FS=y

# ─── Required: Devtmpfs (BusyBox needs it) ──────────────────────────────────
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
```

- [ ] **Step 3.2: Verify**

```bash
grep -c "^CONFIG_" "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/linux-fragment.config"
```
Expected: at least 30 lines.

- [ ] **Step 3.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/linux-fragment.config
git commit -m "feat(buildroot): add kernel config fragment (USB MIDI, WiFi, LEDs, bridge)"
```

---

## Task 4: BusyBox inittab and rcS-related Configuration

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/busybox-inittab`

Buildroot copies this to `/etc/inittab` if `BR2_PACKAGE_BUSYBOX_SHOW_OTHERS` is set, but a more reliable path is via the rootfs-overlay. We'll do that in this task.

Actually the cleanest path: put the inittab in the rootfs-overlay directly.

- [ ] **Step 4.1: Create the inittab in the rootfs-overlay**

```bash
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc"
```

Create `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/inittab`:

```
# /etc/inittab — BusyBox init configuration for RapidBeagle
#
# Format: <id>:<runlevels>:<action>:<process>

# Mount everything once, then start system
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t devtmpfs none /dev
::sysinit:/bin/mount -t tmpfs tmpfs /run
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/mount -o remount,rw /

# Run startup scripts (S* in /etc/init.d/)
::sysinit:/etc/init.d/rcS

# Serial console getty
ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100

# What to do at the "3-finger salute" or shutdown
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/init.d/rcK
::shutdown:/sbin/swapoff -a
::shutdown:/bin/umount -a -r
::restart:/sbin/init
```

- [ ] **Step 4.2: Verify**

```bash
grep -c "^::sysinit\|^ttyS0" "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/inittab"
```
Expected: at least 7 lines.

- [ ] **Step 4.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/inittab
git commit -m "feat(buildroot): add BusyBox inittab with mounts and serial getty"
```

---

## Task 5: Network Interfaces Configuration

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/network/interfaces`
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/wpa_supplicant.conf`

- [ ] **Step 5.1: Create `interfaces`**

```bash
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/network"
```

Create `rootfs-overlay/etc/network/interfaces`:

```
# /etc/network/interfaces — RapidBeagle networking
# usb0:  USB gadget — static 192.168.7.2/24 (host expected at 192.168.7.1)
# eth0:  ethernet (none on PocketBeagle, but config kept for general AM335x)
# wlan0: NOT brought up here. The dotnet app drives wpa_supplicant via control socket.

auto lo
iface lo inet loopback

auto usb0
iface usb0 inet static
    address 192.168.7.2
    netmask 255.255.255.0

# Pre-up retry: usb0 may not exist if the USB gadget driver hasn't loaded yet.
# Make 'auto usb0' a best-effort attempt rather than a hard failure.
allow-hotplug usb0

# eth0 — DHCP if interface is present (skipped automatically if not).
allow-hotplug eth0
iface eth0 inet dhcp
```

- [ ] **Step 5.2: Create empty `wpa_supplicant.conf` template**

Create `rootfs-overlay/etc/wpa_supplicant.conf`:

```
# /etc/wpa_supplicant.conf — RapidBeagle WiFi configuration
#
# This file is intentionally minimal. The dotnet application is expected to
# manage WiFi connections at runtime via the wpa_supplicant control interface
# (CTRL-EVENT-* messages on /var/run/wpa_supplicant/wlan0 socket).
#
# wpa_supplicant is NOT auto-started at boot. The app must launch it when
# it wants to connect:
#   wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
#
# Then it can issue ADD_NETWORK / SET_NETWORK / ENABLE_NETWORK commands.

ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=root
update_config=1
```

- [ ] **Step 5.3: Verify**

```bash
grep -E "address 192.168.7.2|netmask 255.255.255.0" "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/network/interfaces"
grep "ctrl_interface=" "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/wpa_supplicant.conf"
```
Both should match.

- [ ] **Step 5.4: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/network/interfaces buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/wpa_supplicant.conf
git commit -m "feat(buildroot): add network interfaces (usb0 static) and wpa_supplicant template"
```

---

## Task 6: U-Boot Environment (uEnv.txt)

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/uEnv.txt`

This file lives on the boot partition (NOT in rootfs-overlay). The post-image script copies it there.

- [ ] **Step 6.1: Create the uEnv.txt**

```
# uEnv.txt — RapidBeagle U-Boot environment for fast boot
# Loaded by U-Boot from the FAT boot partition.

# Suppress U-Boot console spam
silent=1
loglevel=0

# Zero boot delay — boot immediately on power-on
bootdelay=0

# Kernel boot args: quiet kernel, low printk verbosity
optargs=quiet loglevel=3

# Filesystem types and root device
mmcdev=0
mmcpart=2
mmcroot=/dev/mmcblk0p2 ro
mmcrootfstype=ext4
fdtfile=am335x-pocketbeagle.dtb
console=ttyS0,115200n8

# Boot command: load kernel + DTB, set bootargs, jump
uenvcmd=load mmc ${mmcdev}:1 ${loadaddr} zImage; load mmc ${mmcdev}:1 ${fdtaddr} ${fdtfile}; setenv bootargs root=${mmcroot} rootfstype=${mmcrootfstype} rootwait ${optargs} console=${console}; bootz ${loadaddr} - ${fdtaddr}
```

- [ ] **Step 6.2: Verify**

```bash
grep -E "^silent=1$|^bootdelay=0$|^uenvcmd=" "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/uEnv.txt"
```
Expected: 3 matching lines.

- [ ] **Step 6.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/uEnv.txt
git commit -m "feat(buildroot): add uEnv.txt for U-Boot silent fast-boot"
```

---

## Task 7: SD Image Layout (genimage.cfg)

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/genimage.cfg`

- [ ] **Step 7.1: Create genimage.cfg**

```
# genimage.cfg — RapidBeagle SD card layout
# Two partitions:
#   1. boot.vfat (FAT16, ~16 MB): MLO, u-boot.img, zImage, DTB, uEnv.txt
#   2. rootfs.ext4 (~240 MB): the Linux rootfs

image boot.vfat {
    vfat {
        files = {
            "MLO",
            "u-boot.img",
            "zImage",
            "am335x-pocketbeagle.dtb",
            "uEnv.txt"
        }
    }
    size = 16M
}

image sdcard.img {
    hdimage {
    }

    partition u-boot {
        partition-type = 0xC
        bootable = "true"
        image = "boot.vfat"
    }

    partition rootfs {
        partition-type = 0x83
        image = "rootfs.ext4"
        size = 240M
    }
}
```

- [ ] **Step 7.2: Verify**

```bash
grep -E "image boot.vfat|image sdcard.img|am335x-pocketbeagle.dtb" "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/genimage.cfg"
```
Expected: 3 matches.

- [ ] **Step 7.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/genimage.cfg
git commit -m "feat(buildroot): add genimage.cfg for SD card image assembly"
```

---

## Task 8: post-build.sh — SSH Key Install + sshd Hardening

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/post-build.sh`

- [ ] **Step 8.1: Create post-build.sh**

```bash
#!/usr/bin/env bash
# post-build.sh — runs after rootfs is staged in $TARGET_DIR
#
# Responsibilities:
#   1. Copy user's SSH public key into /root/.ssh/authorized_keys
#   2. Harden /etc/ssh/sshd_config (disable password auth, limit root login)
#   3. Ensure /opt/app/ exists for app deployment
#
# Buildroot calls this with $TARGET_DIR as $1.
# Set RAPIDBEAGLE_SSH_PUBKEY env var to override the default key path.

set -euo pipefail

TARGET_DIR="$1"
PUBKEY_SRC="${RAPIDBEAGLE_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

# ── Step 1: SSH authorized_keys ──────────────────────────────────────────────
if [[ ! -f "$PUBKEY_SRC" ]]; then
    echo "post-build: WARNING: SSH public key not found at $PUBKEY_SRC"
    echo "post-build: WARNING: SSH key auth will not be set up."
    echo "post-build: WARNING: Set RAPIDBEAGLE_SSH_PUBKEY env var to override."
else
    mkdir -p "$TARGET_DIR/root/.ssh"
    chmod 700 "$TARGET_DIR/root/.ssh"
    cp "$PUBKEY_SRC" "$TARGET_DIR/root/.ssh/authorized_keys"
    chmod 600 "$TARGET_DIR/root/.ssh/authorized_keys"
    echo "post-build: installed SSH key from $PUBKEY_SRC"
fi

# ── Step 2: Harden sshd_config ───────────────────────────────────────────────
SSHD_CONFIG="$TARGET_DIR/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    echo "post-build: hardened sshd_config (no password, root key-only)"
fi

# ── Step 3: Ensure /opt/app exists ───────────────────────────────────────────
mkdir -p "$TARGET_DIR/opt/app"
echo "post-build: /opt/app/ ready for app deployment"

# ── Step 4: Mark scripts executable (defensive — they should already be) ────
for script in "$TARGET_DIR/etc/init.d"/S*; do
    [[ -f "$script" ]] && chmod +x "$script"
done

echo "post-build: complete."
```

- [ ] **Step 8.2: Make executable and lint**

```bash
chmod +x "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/post-build.sh"
bash -n "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/post-build.sh"
```
Expected: no syntax errors.

If shellcheck is available (in WSL2):
```bash
shellcheck "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/post-build.sh"
```
Expected: clean.

- [ ] **Step 8.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/post-build.sh
git commit -m "feat(buildroot): add post-build.sh (SSH key install + sshd hardening)"
```

---

## Task 9: post-image.sh — genimage Orchestration

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh`

- [ ] **Step 9.1: Create post-image.sh**

```bash
#!/usr/bin/env bash
# post-image.sh — runs after rootfs/kernel/U-Boot are built
#
# Responsibilities:
#   1. Copy uEnv.txt into the binaries dir so genimage picks it up
#   2. Run genimage to assemble sdcard.img from the partition layout

set -euo pipefail

BOARD_DIR="$(dirname "$(readlink -f "$0")")"
GENIMAGE_CFG="$BOARD_DIR/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# ── Step 1: Stage uEnv.txt for the boot partition ───────────────────────────
cp "$BOARD_DIR/uEnv.txt" "${BINARIES_DIR}/uEnv.txt"
echo "post-image: staged uEnv.txt"

# ── Step 2: Run genimage ─────────────────────────────────────────────────────
rm -rf "${GENIMAGE_TMP}"
genimage \
    --rootpath   "${TARGET_DIR}"   \
    --tmppath    "${GENIMAGE_TMP}" \
    --inputpath  "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config     "${GENIMAGE_CFG}"

echo "post-image: sdcard.img ready at ${BINARIES_DIR}/sdcard.img"
```

- [ ] **Step 9.2: Make executable + lint**

```bash
chmod +x "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh"
bash -n "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh"
```
Expected: no syntax errors.

- [ ] **Step 9.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh
git commit -m "feat(buildroot): add post-image.sh for genimage SD assembly"
```

---

## Task 10: rootfs-overlay — S98-pb-heartbeat Service

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S98-pb-heartbeat`

- [ ] **Step 10.1: Create the heartbeat init script**

```bash
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d"
```

Create `rootfs-overlay/etc/init.d/S98-pb-heartbeat`:

```sh
#!/bin/sh
# S98-pb-heartbeat — USR0 LED boot heartbeat
#
# Three states:
#   No /run/boot-complete                    → fast blink (5 Hz)
#   /run/boot-complete, no live /run/app.pid → slow blink (0.5 Hz)
#   /run/app.pid points at a live process    → steady on
#
# Forks into the background as a child of init. Stop with `S98-pb-heartbeat stop`.

DAEMON=pb-heartbeat
PIDFILE=/run/$DAEMON.pid
LED=/sys/class/leds/beaglebone:green:usr0
BOOT_FLAG=/run/boot-complete
APP_PID_FILE=/run/app.pid

start() {
    if [ ! -d "$LED" ]; then
        echo "S98-pb-heartbeat: LED path $LED not found — exiting"
        return 0
    fi

    # Reclaim USR0 from the kernel "heartbeat" trigger
    echo none > "$LED/trigger" 2>/dev/null || true
    echo 0    > "$LED/brightness" 2>/dev/null || true

    # Background loop
    (
        while true; do
            if [ -f "$APP_PID_FILE" ]; then
                APID=$(cat "$APP_PID_FILE" 2>/dev/null)
                if [ -n "$APID" ] && [ -d "/proc/$APID" ]; then
                    # App alive — steady on
                    echo 1 > "$LED/brightness" 2>/dev/null || true
                    sleep 2
                    continue
                fi
            fi
            if [ -f "$BOOT_FLAG" ]; then
                # Slow blink: 1s on, 1s off
                echo 1 > "$LED/brightness" 2>/dev/null || true
                sleep 1
                echo 0 > "$LED/brightness" 2>/dev/null || true
                sleep 1
            else
                # Fast blink: 100ms on, 100ms off
                echo 1 > "$LED/brightness" 2>/dev/null || true
                sleep 0.1
                echo 0 > "$LED/brightness" 2>/dev/null || true
                sleep 0.1
            fi
        done
    ) &

    echo $! > "$PIDFILE"
    echo "S98-pb-heartbeat: started (pid $(cat "$PIDFILE"))"
}

stop() {
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
    # Restore kernel heartbeat trigger so the LED still works without us
    echo heartbeat > "$LED/trigger" 2>/dev/null || true
    echo "S98-pb-heartbeat: stopped"
}

case "$1" in
    start) start ;;
    stop)  stop ;;
    restart) stop; start ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
```

- [ ] **Step 10.2: Make executable + lint**

```bash
chmod +x "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S98-pb-heartbeat"
bash -n "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S98-pb-heartbeat"
```
Expected: no syntax errors.

- [ ] **Step 10.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S98-pb-heartbeat
git commit -m "feat(buildroot): add S98-pb-heartbeat init script (USR0 LED state machine)"
```

---

## Task 11: rootfs-overlay — S99-app-launcher Service

**Files:**
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S99-app-launcher`
- Create: `buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/opt/app/.gitkeep`

- [ ] **Step 11.1: Create the launcher script**

```bash
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/opt/app"
touch "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/opt/app/.gitkeep"
```

Create `rootfs-overlay/etc/init.d/S99-app-launcher`:

```sh
#!/bin/sh
# S99-app-launcher — launch the RapidBeagle dotnet AOT application
#
# Convention: the AOT-compiled binary is dropped at /opt/app/rapidbeagle-app
# via `scp` after first boot. If the binary is missing or non-executable,
# this script silently exits 0 — the device still boots, SSH works, and
# you can deploy and reboot.

APP=/opt/app/rapidbeagle-app
PIDFILE=/run/app.pid
LOGFILE=/var/log/app.log
BOOT_FLAG=/run/boot-complete

start() {
    # Mark boot complete so the heartbeat transitions to "boot done"
    touch "$BOOT_FLAG"

    if [ ! -x "$APP" ]; then
        echo "S99-app-launcher: $APP not found or not executable — skipping"
        return 0
    fi

    # Make sure /var/log exists (it's tmpfs, recreated each boot)
    mkdir -p /var/log

    # Launch the app in background, capture PID
    "$APP" >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "S99-app-launcher: started $APP (pid $(cat "$PIDFILE"))"
}

stop() {
    if [ -f "$PIDFILE" ]; then
        APID=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$APID" ] && [ -d "/proc/$APID" ]; then
            kill "$APID" 2>/dev/null || true
            # Give it 5 seconds to exit gracefully
            i=0
            while [ -d "/proc/$APID" ] && [ "$i" -lt 5 ]; do
                sleep 1
                i=$((i + 1))
            done
            # Force-kill if still alive
            [ -d "/proc/$APID" ] && kill -9 "$APID" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi
    echo "S99-app-launcher: stopped"
}

case "$1" in
    start) start ;;
    stop)  stop ;;
    restart) stop; start ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
```

- [ ] **Step 11.2: Make executable + lint**

```bash
chmod +x "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S99-app-launcher"
bash -n "I:/Source/repos/RapidBeagle/buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S99-app-launcher"
```
Expected: no syntax errors.

- [ ] **Step 11.3: Commit**

```bash
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S99-app-launcher buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/opt/app/.gitkeep
git commit -m "feat(buildroot): add S99-app-launcher and reserve /opt/app/ deploy dir"
```

---

## Task 12: build.sh Wrapper

**Files:**
- Create: `buildroot/scripts/build.sh`

- [ ] **Step 12.1: Create the wrapper**

```bash
mkdir -p "I:/Source/repos/RapidBeagle/buildroot/scripts"
```

Create `buildroot/scripts/build.sh`:

```bash
#!/usr/bin/env bash
# build.sh — RapidBeagle Buildroot build wrapper
#
# Usage:
#   ./build.sh                # configure (if needed) and build
#   ./build.sh defconfig      # apply rapidbeagle_pb_defconfig only
#   ./build.sh menuconfig     # open Buildroot's menuconfig
#   ./build.sh clean          # clean build artifacts
#   ./build.sh distclean      # nuke .config too (full reset)
#
# Env:
#   BUILDROOT_DIR              path to Buildroot clone (default: $HOME/buildroot)
#   RAPIDBEAGLE_SSH_PUBKEY     path to SSH pubkey for image (default: $HOME/.ssh/id_ed25519.pub)
#   J                          parallel jobs (default: $(nproc))

set -euo pipefail

# ── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDROOT_EXT_DIR="$(dirname "$SCRIPT_DIR")/external"
BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/buildroot}"
DEFCONFIG="rapidbeagle_pb_defconfig"
J="${J:-$(nproc 2>/dev/null || echo 2)}"

# ── Sanity checks ────────────────────────────────────────────────────────────
if [[ ! -d "$BUILDROOT_DIR" ]]; then
    echo "ERROR: Buildroot not found at $BUILDROOT_DIR" >&2
    echo "Clone it first:  git clone https://git.busybox.net/buildroot $BUILDROOT_DIR" >&2
    echo "Or set BUILDROOT_DIR to override the path." >&2
    exit 1
fi

if [[ ! -d "$BUILDROOT_EXT_DIR" ]]; then
    echo "ERROR: External tree not found at $BUILDROOT_EXT_DIR" >&2
    exit 1
fi

# ── Export env vars Buildroot/scripts will read ──────────────────────────────
export BR2_EXTERNAL="$BUILDROOT_EXT_DIR"
export RAPIDBEAGLE_SSH_PUBKEY="${RAPIDBEAGLE_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

cd "$BUILDROOT_DIR"

case "${1:-build}" in
    defconfig)
        make BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"
        ;;
    menuconfig)
        # Apply defconfig first if .config doesn't exist
        [[ -f .config ]] || make BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"
        make menuconfig
        ;;
    clean)
        make clean
        ;;
    distclean)
        make distclean
        ;;
    build|all)
        # Apply defconfig if not yet configured
        if [[ ! -f .config ]]; then
            echo "build.sh: applying $DEFCONFIG (first build)"
            make BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"
        fi
        echo "build.sh: building with -j$J ..."
        make -j"$J"
        echo ""
        echo "================================================================"
        echo "build.sh: BUILD COMPLETE"
        echo "  Image: $BUILDROOT_DIR/output/images/sdcard.img"
        echo "  Flash: sudo $SCRIPT_DIR/flash-sdcard.sh /dev/sdX"
        echo "================================================================"
        ;;
    *)
        echo "Usage: $0 [defconfig|menuconfig|build|clean|distclean]" >&2
        exit 1
        ;;
esac
```

- [ ] **Step 12.2: Make executable + lint**

```bash
chmod +x "I:/Source/repos/RapidBeagle/buildroot/scripts/build.sh"
bash -n "I:/Source/repos/RapidBeagle/buildroot/scripts/build.sh"
```
Expected: no syntax errors.

- [ ] **Step 12.3: Commit**

```bash
git add buildroot/scripts/build.sh
git commit -m "feat(buildroot): add build.sh wrapper (defconfig + parallel build)"
```

---

## Task 13: flash-sdcard.sh Wrapper

**Files:**
- Create: `buildroot/scripts/flash-sdcard.sh`

- [ ] **Step 13.1: Create the flasher**

Create `buildroot/scripts/flash-sdcard.sh`:

```bash
#!/usr/bin/env bash
# flash-sdcard.sh — RapidBeagle interactive SD card flasher
#
# Usage:  sudo ./flash-sdcard.sh /dev/sdX
#
# Safety features:
#   - Refuses to write to /dev/sda (likely your boot disk)
#   - Refuses to run without root
#   - Shows target device info and asks for explicit "yes" confirmation
#   - Unmounts existing partitions before write
#   - Verifies image exists before doing anything destructive

set -euo pipefail

DEVICE="${1:-}"
DEFAULT_IMAGE="$HOME/buildroot/output/images/sdcard.img"
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"

# ── Help / no-arg case ───────────────────────────────────────────────────────
if [[ -z "$DEVICE" ]]; then
    cat <<EOF
Usage: sudo $0 /dev/sdX

Required:  the target block device (NOT a partition — pass /dev/sdb, NOT /dev/sdb1).

Available block devices on this host (excluding /dev/sda):
EOF
    lsblk -d -o NAME,SIZE,MODEL,VENDOR | awk 'NR==1 || $1 != "sda"'
    echo ""
    echo "Override image path with:  IMAGE=/path/to/sdcard.img sudo $0 /dev/sdX"
    echo "Default image path:        $DEFAULT_IMAGE"
    exit 1
fi

# ── Sanity checks ────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Must run as root. Use:  sudo $0 $DEVICE" >&2
    exit 1
fi

if [[ "$DEVICE" == "/dev/sda" ]]; then
    echo "ERROR: Refusing to write to /dev/sda — that's almost always your boot disk." >&2
    echo "       If you genuinely want to flash /dev/sda, edit this script." >&2
    exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: $DEVICE is not a block device" >&2
    exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
    echo "ERROR: Image not found: $IMAGE" >&2
    echo "       Build it first:  $(dirname "$0")/build.sh" >&2
    exit 1
fi

# ── Show target + confirm ────────────────────────────────────────────────────
echo "Target device:"
lsblk "$DEVICE"
echo ""
echo "Image:         $IMAGE  ($(du -h "$IMAGE" | cut -f1))"
echo ""
echo "WARNING: This will DESTROY all data on $DEVICE."
read -r -p "Type 'yes' to proceed: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# ── Unmount any mounted partitions on the target ────────────────────────────
for part in "${DEVICE}"*; do
    if [[ "$part" != "$DEVICE" ]] && mountpoint -q "$part" 2>/dev/null; then
        echo "Unmounting $part ..."
        umount "$part" || true
    fi
done

# ── Write with progress ──────────────────────────────────────────────────────
echo "Writing image to $DEVICE ..."
dd if="$IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress
sync

echo ""
echo "================================================================"
echo "flash-sdcard.sh: COMPLETE — safe to remove the SD card."
echo "================================================================"
```

- [ ] **Step 13.2: Make executable + lint**

```bash
chmod +x "I:/Source/repos/RapidBeagle/buildroot/scripts/flash-sdcard.sh"
bash -n "I:/Source/repos/RapidBeagle/buildroot/scripts/flash-sdcard.sh"
```
Expected: no syntax errors.

- [ ] **Step 13.3: Commit**

```bash
git add buildroot/scripts/flash-sdcard.sh
git commit -m "feat(buildroot): add flash-sdcard.sh with safety checks"
```

---

## Task 14: buildroot/README.md

**Files:**
- Create: `buildroot/README.md`

- [ ] **Step 14.1: Create the README**

```markdown
# RapidBeagle — Buildroot Image

Custom Linux image for PocketBeagle (TI AM335x) targeting **<10 second power-on to NativeAOT dotnet app**.

This is the Buildroot-based approach. See the project root `README.md` for the alternative (Debian-script approach in the parent repo).

## Quick start

### One-time setup (in WSL2 Ubuntu 22.04 / 24.04)

Install build dependencies:
```bash
sudo apt update
sudo apt install -y build-essential git cpio unzip rsync bc python3 \
                    file wget libncurses-dev gawk
```

Clone Buildroot and this repo:
```bash
cd ~
git clone https://git.busybox.net/buildroot
git clone https://github.com/kurtnelle/RapidBeagle.git
```

> **Important:** clone into the WSL2 native filesystem (`~/`), NOT under `/mnt/c/`. The Windows mount is roughly 10x slower for Buildroot's small-file workload.

Make sure your SSH key is at `~/.ssh/id_ed25519.pub` (it gets baked into the image at build time so you can SSH in without a password). Override with `RAPIDBEAGLE_SSH_PUBKEY=/path/to/key.pub`.

### Build

```bash
cd ~/RapidBeagle/buildroot/scripts
./build.sh
```

First build: 30–60 minutes (Buildroot compiles kernel + BusyBox + glibc + openssh + wpa_supplicant from source). Incremental rebuilds: 2–10 minutes.

### Flash

Insert SD card, find its device node (`lsblk`), then:

```bash
sudo ./flash-sdcard.sh /dev/sdX
```

Refuses to write to `/dev/sda` and asks for explicit `yes` confirmation.

### Boot

Insert the SD card into the PocketBeagle and power on. After boot:

- USR0 LED fast-blinks during boot, slow-blinks after init completes
- SSH reachable at `root@192.168.7.2` over USB gadget (no password — your key was baked in)

### Deploy your AOT'd dotnet app

```bash
dotnet publish -c Release -r linux-arm --self-contained -p:PublishAot=true -o publish/
scp publish/rapidbeagle-app root@192.168.7.2:/opt/app/
ssh root@192.168.7.2 reboot
```

After reboot, the LED goes steady on once the app is running. Boot to app responding: ~5–7 seconds.

## What's in the image

| Component | Why |
|---|---|
| Linux 6.6.x kernel (stripped via fragment) | USB MIDI, USB WiFi, USB gadget, LEDs, GPIO — nothing else |
| U-Boot (silent, zero-delay boot) | Tuned to ~0.5s |
| BusyBox init (no systemd) | ~0.5s init overhead |
| glibc + libstdc++ | NativeAOT runtime libs |
| OpenSSH | dev access (port 22, key auth only) |
| wpa_supplicant | WiFi infrastructure (NOT auto-started; dotnet app drives it) |
| ifupdown scripts + `/etc/network/interfaces` | usb0 static, eth0 DHCP if present |
| Three init scripts | S40-network (auto), S98-pb-heartbeat, S99-app-launcher |

## What's NOT in the image

- systemd, dbus, polkit
- NetworkManager
- apt, dpkg, package management
- Bluetooth
- HDA / I2S audio (USB MIDI only)
- Bash (BusyBox `ash` only)
- Documentation, man pages, locales (English only)
- dotnet runtime — your app is AOT-compiled to native ARM

## Layout

```
buildroot/
├── README.md                      ← this file
├── external/                      ← BR2_EXTERNAL tree
│   ├── external.desc
│   ├── external.mk
│   ├── Config.in
│   ├── configs/rapidbeagle_pb_defconfig
│   └── board/rapidbeagle/pocketbeagle/
│       ├── linux-fragment.config
│       ├── busybox-inittab
│       ├── interfaces
│       ├── uEnv.txt
│       ├── genimage.cfg
│       ├── post-build.sh
│       ├── post-image.sh
│       └── rootfs-overlay/etc/init.d/{S98-pb-heartbeat,S99-app-launcher}
└── scripts/
    ├── build.sh
    └── flash-sdcard.sh
```

## Iterating

- **App code change:** `dotnet publish ... && scp ...` — no rebuild needed
- **Image config change:** edit a file under `external/`, then `./build.sh` (incremental, 2–10 min), then reflash
- **Want a quick boot-time test?** Use the PowerShell timer documented in the root README

## Troubleshooting

- **Build fails on first attempt with toolchain errors** — clear the build dir: `./build.sh distclean && ./build.sh`
- **`sdcard.img` not found after build** — check `output/images/` for partial artifacts; the post-image script may have failed
- **SSH connection refused after boot** — wait ~5s for sshd to come up after init, or check the serial console at 115200 baud on `ttyS0`
- **LED not blinking** — the `pb-heartbeat` script may have failed; SSH in and run `/etc/init.d/S98-pb-heartbeat start` manually to see errors

See the design spec at `docs/superpowers/specs/2026-04-26-rapidbeagle-buildroot-design.md` for the full architecture rationale.
```

- [ ] **Step 14.2: Verify**

```bash
grep -E "^## |^### " "I:/Source/repos/RapidBeagle/buildroot/README.md" | head -10
```
Expected: at least 8 sections.

- [ ] **Step 14.3: Commit**

```bash
git add buildroot/README.md
git commit -m "docs(buildroot): add README with quick-start, layout, and troubleshooting"
```

---

## Task 15: Update Root README.md

**Files:**
- Create: `README.md` (root) — describes both approaches

- [ ] **Step 15.1: Create the root README**

```markdown
# RapidBeagle

Two approaches for fast-booting a PocketBeagle (TI AM335x) into a NativeAOT-compiled .NET application.

## Which one should I use?

| Need | Recommendation |
|---|---|
| Get a working setup **today** on an existing Debian image | **Approach 1: Optimization script** |
| Hit a hard **<10 second boot** target | **Approach 2: Buildroot custom image** |
| Iterate on the OS itself (kernel, packages, init) | **Approach 2: Buildroot** |
| Don't have a Linux build host | **Approach 1: Debian script** |
| Production single-purpose appliance | **Approach 2: Buildroot** |

---

## Approach 1: Debian Optimization Script

Run on a stock BeagleBoard.org Debian image. Disables non-essential services, blacklists unneeded kernel modules, patches the kernel cmdline for `quiet` boot, installs an LED heartbeat service, creates a `dotnet-app.service` placeholder, and writes a `BOOT_COMPLETE.txt` marker after boot.

- **Files:** `optimize-pocketbeagle-boot.sh`, `restore-pocketbeagle-boot.sh`
- **Result:** Boot ~15–20s on optimized Debian
- **Spec:** [docs/superpowers/specs/2026-04-25-pocketbeagle-boot-design.md](docs/superpowers/specs/2026-04-25-pocketbeagle-boot-design.md)

### Quick use

```bash
scp optimize-pocketbeagle-boot.sh root@192.168.7.2:/root/
ssh root@192.168.7.2
sudo ./optimize-pocketbeagle-boot.sh --dry-run     # preview
sudo ./optimize-pocketbeagle-boot.sh --apply       # apply
# To undo:
sudo ./optimize-pocketbeagle-boot.sh --restore
```

---

## Approach 2: Buildroot Custom Image

Build a fully custom Linux image from scratch using Buildroot. Stripped kernel, BusyBox init, no systemd, no apt — just glibc + OpenSSH + wpa_supplicant + your AOT'd binary.

- **Directory:** [buildroot/](buildroot/)
- **Result:** Boot ~5–7s power-on to NativeAOT app responding
- **Spec:** [docs/superpowers/specs/2026-04-26-rapidbeagle-buildroot-design.md](docs/superpowers/specs/2026-04-26-rapidbeagle-buildroot-design.md)
- **Build host:** Linux or WSL2 Ubuntu 22.04+

### Quick start

```bash
# In WSL2:
cd ~
git clone https://git.busybox.net/buildroot
git clone https://github.com/kurtnelle/RapidBeagle.git
cd RapidBeagle/buildroot/scripts
./build.sh
sudo ./flash-sdcard.sh /dev/sdX
```

See [buildroot/README.md](buildroot/README.md) for full instructions.

---

## Measuring boot time (PowerShell)

After flashing, time power-on to first SSH response:

```powershell
$s = Get-Date
do {
    ssh -o ConnectTimeout=1 -o BatchMode=yes root@192.168.7.2 "true" 2>$null
} until ($LASTEXITCODE -eq 0)
"{0:N2}s" -f ((Get-Date) - $s).TotalSeconds
```

Start the timer the moment you apply power. The script polls SSH every ~500ms until it answers.

---

## Repository layout

```
RapidBeagle/
├── README.md                                ← you are here
├── optimize-pocketbeagle-boot.sh            ← Approach 1: Debian script
├── restore-pocketbeagle-boot.sh             ← Approach 1: undo
├── .gitattributes                           ← LF line endings for shell scripts
├── buildroot/                               ← Approach 2: full custom image
│   ├── README.md
│   ├── external/                            ← Buildroot BR2_EXTERNAL tree
│   └── scripts/                             ← build.sh, flash-sdcard.sh
└── docs/superpowers/
    ├── specs/                               ← design specs
    └── plans/                               ← implementation plans
```

## Hardware

- **Target:** PocketBeagle (TI AM335x, ARMv7 single-core Cortex-A8 @ 1 GHz)
- **Out of scope:** PocketBeagle 2 (different SoC — AM6232, aarch64). Would need a separate defconfig.

## License

The contents of this repository are personal/project-internal at this stage. A formal LICENSE file can be added later when/if the project is published more broadly.
```

- [ ] **Step 15.2: Verify**

```bash
grep -E "Approach 1|Approach 2|buildroot" "I:/Source/repos/RapidBeagle/README.md"
```
Expected: at least 4 matches.

- [ ] **Step 15.3: Commit**

```bash
git add README.md
git commit -m "docs: add root README describing both Debian-script and Buildroot approaches"
```

---

## Task 16: First-Build Verification (Manual)

This task is documentation only — no files to commit. It guides the user through the first WSL2 build to validate everything works.

**This task cannot be performed in the Windows working directory** — it requires WSL2 (or another Linux host). The implementer subagent should NOT attempt to run the build; instead, write the verification checklist into a doc and stop.

**Files:**
- Create: `buildroot/FIRST_BUILD_CHECKLIST.md`

- [ ] **Step 16.1: Create the checklist**

```markdown
# First Build Checklist

Use this the first time you run the Buildroot build to make sure everything is set up correctly. Subsequent builds are just `./build.sh`.

## Before you start

- [ ] WSL2 with Ubuntu 22.04 or 24.04 installed
- [ ] At least 50 GB free disk space in WSL2's filesystem
- [ ] At least 16 GB RAM (8 GB will work but is slower)
- [ ] Stable internet (Buildroot downloads ~1–2 GB of source tarballs on first run)

## Setup

- [ ] Install dependencies in WSL2:
      ```bash
      sudo apt update
      sudo apt install -y build-essential git cpio unzip rsync bc python3 \
                          file wget libncurses-dev gawk
      ```
- [ ] Clone Buildroot to your WSL2 home (`~/buildroot`):
      ```bash
      git clone https://git.busybox.net/buildroot ~/buildroot
      ```
- [ ] Clone this repo to your WSL2 home (`~/RapidBeagle`):
      ```bash
      git clone https://github.com/kurtnelle/RapidBeagle.git ~/RapidBeagle
      ```
- [ ] Confirm SSH key exists at `~/.ssh/id_ed25519.pub`:
      ```bash
      ls -la ~/.ssh/id_ed25519.pub
      ```
      If not, generate one: `ssh-keygen -t ed25519`

## First build

- [ ] Run the build:
      ```bash
      cd ~/RapidBeagle/buildroot/scripts
      ./build.sh
      ```
- [ ] Confirm `defconfig` applies cleanly (look for "make olddefconfig" or no errors)
- [ ] Confirm Buildroot starts downloading and compiling (this is the long part)
- [ ] Wait for build to complete (30–60 minutes typically)
- [ ] Confirm `sdcard.img` exists:
      ```bash
      ls -la ~/buildroot/output/images/sdcard.img
      ```
      Expected size: ~256 MB

## First flash and boot

- [ ] Insert SD card into your computer
- [ ] Find its device node:
      ```bash
      lsblk -d -o NAME,SIZE,MODEL
      ```
      It's usually `/dev/sdb` (NOT `sda` — that's your boot disk)
- [ ] Flash:
      ```bash
      sudo ~/RapidBeagle/buildroot/scripts/flash-sdcard.sh /dev/sdb
      ```
- [ ] Insert SD card into PocketBeagle, plug into your computer via USB
- [ ] Wait ~10 seconds for boot
- [ ] Confirm USR0 LED is blinking (slow blink = boot complete, no app deployed)
- [ ] Confirm SSH works:
      ```bash
      ssh root@192.168.7.2 "uname -a"
      ```

## Deploy your AOT'd app (when you have one)

- [ ] On your dev machine: `dotnet publish -c Release -r linux-arm --self-contained -p:PublishAot=true -o publish/`
- [ ] SCP the binary: `scp publish/rapidbeagle-app root@192.168.7.2:/opt/app/`
- [ ] Reboot: `ssh root@192.168.7.2 reboot`
- [ ] Confirm USR0 LED goes steady on after boot (= app running)

## Measure boot time

From your Windows host (PowerShell):
```powershell
$s = Get-Date
do {
    ssh -o ConnectTimeout=1 -o BatchMode=yes root@192.168.7.2 "true" 2>$null
} until ($LASTEXITCODE -eq 0)
"{0:N2}s" -f ((Get-Date) - $s).TotalSeconds
```

Start the timer the moment you apply power. Target: under 10 seconds. Realistic: 5–7 seconds.

## Troubleshooting

If something doesn't work, see `buildroot/README.md` § Troubleshooting.

If the build itself fails, the most common causes are:
1. Missing build dependency (re-run `apt install` step)
2. Disk full (Buildroot uses 30–50 GB)
3. Network issue downloading source tarballs (re-run `./build.sh`; Buildroot resumes)
4. WSL2 mount path used (`/mnt/c/...`) — this is unsupported. Move to `~/`.
```

- [ ] **Step 16.2: Verify**

```bash
ls -la "I:/Source/repos/RapidBeagle/buildroot/FIRST_BUILD_CHECKLIST.md"
```
Expected: file exists.

- [ ] **Step 16.3: Commit**

```bash
git add buildroot/FIRST_BUILD_CHECKLIST.md
git commit -m "docs(buildroot): add first-build checklist for WSL2"
```

---

## Task 17: Push to GitHub

After all tasks complete, push to the existing remote:

- [ ] **Step 17.1: Push**

```bash
cd "I:/Source/repos/RapidBeagle"
git push origin main
```
Expected: all commits land on `kurtnelle/RapidBeagle`.

- [ ] **Step 17.2: Verify**

```bash
gh repo view kurtnelle/RapidBeagle --json url,pushedAt
```
Expected: `pushedAt` is recent.

---

## Out-of-plan handoff to user

After Task 17, the implementer should report:

> All Buildroot configuration is in place and pushed. The next steps are MANUAL and run on YOUR side (WSL2 build host):
>
> 1. Follow `buildroot/FIRST_BUILD_CHECKLIST.md` for the first WSL2 build
> 2. Flash the resulting SD card image
> 3. Boot the PocketBeagle and confirm SSH works
> 4. Deploy your AOT'd app and time the boot

The implementer cannot run the actual Buildroot build from a Windows working directory.
