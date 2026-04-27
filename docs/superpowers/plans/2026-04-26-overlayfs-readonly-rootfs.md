# Overlayfs Read-Only Rootfs + FAT32 Data Partition — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the RapidBeagle SD card OS read-only after boot (writes go to RAM tmpfs), add a FAT32 user-data partition for `config.txt` and app binaries, and make `usb0` plug-and-play with both PCs (static IP) and Android phones (DHCP client).

**Architecture:** Three changes on top of the existing Buildroot image: (1) a third FAT32 partition mounted RO at `/data`, (2) a `/sbin/overlay-init` PID-1 wrapper that builds an overlayfs (lower=ext4 rootfs RO, upper=tmpfs) and `switch_root`s into it before BusyBox init runs, (3) `S39-usb-gadget` tries DHCP for 3s on `usb0` then falls back to static `192.168.7.2`.

**Tech Stack:** Buildroot 2024.02.13, Linux kernel 6.6.30 (overlayfs built-in), BusyBox ash + udhcpc + switch_root, configfs USB gadgets, ARMv7 single-core. Build host is WSL2 Ubuntu (`~/buildroot`, `~/RapidBeagle`); device is PocketBeagle accessed via USB-NCM at `192.168.7.2` and serial COM6.

**Spec:** [docs/superpowers/specs/2026-04-26-overlayfs-readonly-rootfs-design.md](../specs/2026-04-26-overlayfs-readonly-rootfs-design.md)

---

## Conventions used in this plan

- All file paths under `buildroot/external/board/rapidbeagle/pocketbeagle/` are abbreviated as `BRD/`. Resolve as `I:\Source\repos\RapidBeagle\buildroot\external\board\rapidbeagle\pocketbeagle\<rest>`.
- All edits are made in the Windows checkout (`I:\Source\repos\RapidBeagle`); the WSL2 clone (`~/RapidBeagle`) is synced via `scp -P 2222` snippets from the handoff doc.
- "Build" = `ssh -p 2222 root@localhost "cd ~/buildroot && make -j16"`. The repo's `build.sh` auto-copies `output/images/sdcard.img` to `I:\Source\repos\RapidBeagle\dist\sdcard.img` on success.
- "Flash" = `sudo ~/RapidBeagle/buildroot/scripts/flash-sdcard.sh /dev/sdX` with the SD inserted in the WSL2 host's reader.
- "Boot" = `ssh-keygen -R 192.168.7.2` then power-cycle the device. SSH at `root@192.168.7.2`.
- "Serial" = `python "C:\Users\shawn\AppData\Local\Temp\pb-serial.py" "<command>"` over COM6.
- Each phase ends with a build+flash+verify cycle. Phase 1 requires a full kernel rebuild (~5-10 min); phases 2-4 are incremental rootfs rebuilds (~1-2 min).

---

## File map

**New files:**
- `BRD/rootfs-overlay/sbin/overlay-init` — PID 1 wrapper that sets up overlayfs.
- `BRD/rootfs-overlay/data/.gitkeep` — creates the `/data` mount point in the rootfs.
- `BRD/rootfs-overlay/etc/init.d/S10-mount-data` — mounts `/dev/mmcblk0p3` RO at `/data`.
- `BRD/data/config.txt` — template config copied into the FAT32 partition by `post-image.sh`.
- `BRD/data/README.txt` — short note explaining the partition.

**Modified files:**
- `BRD/genimage.cfg` — adds 3rd partition, shrinks rootfs.
- `BRD/post-image.sh` — generates the FAT32 image with `config.txt` + `README.txt`.
- `BRD/uEnv.txt` — adds `init=/sbin/overlay-init` to bootargs.
- `BRD/linux-fragment.config` — adds `CONFIG_OVERLAY_FS=y`.
- `BRD/rootfs-overlay/etc/init.d/S39-usb-gadget` — replaces `ifup usb0` with DHCP-then-static block.
- `BRD/rootfs-overlay/etc/init.d/S99-app-launcher` — searches `/data/$app_binary`, then `/data/rapidbeagle-app`, then `/opt/app/rapidbeagle-app`.
- `BRD/rootfs-overlay/etc/network/interfaces` — removes `usb0` stanza.

---

# Phase 1 — Data partition + kernel config

This phase creates the third FAT32 partition, mounts it RO at `/data` on boot, and ensures the kernel has overlayfs support compiled in. **No overlayfs is activated yet** — that's Phase 2. We do this first so the kernel rebuild (slow) happens once and the rest of the work is fast incremental rootfs rebuilds.

## Task 1.1 — Add `CONFIG_OVERLAY_FS=y` to the kernel fragment

**Files:**
- Modify: `BRD/linux-fragment.config` (currently has `CONFIG_TMPFS=y` at line 154 but no overlayfs)

- [ ] **Step 1: Add the overlay fragment**

Append after the `CONFIG_CONFIGFS_FS=y` line (line 155) so it stays grouped with the other "Required" filesystem configs:

```
# ─── Required: overlayfs for read-only rootfs (overlay-init / Phase 1+2) ───
CONFIG_OVERLAY_FS=y
```

The exact replacement is:

`old_string`:
```
# ─── Required: ext4 for rootfs ──────────────────────────────────────────────
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_VFAT_FS=y
CONFIG_TMPFS=y
CONFIG_CONFIGFS_FS=y
```

`new_string`:
```
# ─── Required: ext4 for rootfs ──────────────────────────────────────────────
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_VFAT_FS=y
CONFIG_TMPFS=y
CONFIG_CONFIGFS_FS=y

# ─── Required: overlayfs for read-only rootfs (overlay-init) ────────────────
CONFIG_OVERLAY_FS=y
```

- [ ] **Step 2: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/linux-fragment.config
git commit -m "feat(buildroot): enable CONFIG_OVERLAY_FS for read-only rootfs"
```

---

## Task 1.2 — Add `/data` mount-point directory to the rootfs overlay

**Files:**
- Create: `BRD/rootfs-overlay/data/.gitkeep`

- [ ] **Step 1: Create the empty directory marker**

The Buildroot `rootfs-overlay/` mechanism only copies directories that contain at least one file. A `.gitkeep` is conventional and will be copied to `/data/.gitkeep` on the device, where it's harmless (the mount over `/data` hides it).

Write file `I:\Source\repos\RapidBeagle\buildroot\external\board\rapidbeagle\pocketbeagle\rootfs-overlay\data\.gitkeep` with content (empty file is fine, but include a comment for human readers):

```
# Placeholder so Buildroot copies this directory into the rootfs.
# At runtime, /data is mounted from /dev/mmcblk0p3 (FAT32) by S10-mount-data.
```

- [ ] **Step 2: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/data/.gitkeep
git commit -m "feat(buildroot): create /data mount point in rootfs"
```

---

## Task 1.3 — Add `S10-mount-data` init script

**Files:**
- Create: `BRD/rootfs-overlay/etc/init.d/S10-mount-data`

- [ ] **Step 1: Write the init script**

Write file `I:\Source\repos\RapidBeagle\buildroot\external\board\rapidbeagle\pocketbeagle\rootfs-overlay\etc\init.d\S10-mount-data` with content:

```sh
#!/bin/sh
# S10-mount-data — mount the user-editable FAT32 data partition at /data
#
# /data holds:
#   - config.txt        (key=value config, read by init scripts and the app)
#   - rapidbeagle-app   (optional: app binary; overrides /opt/app/rapidbeagle-app)
#   - any other files the user drops on the FAT32 partition from a PC
#
# Mounted READ-ONLY on the device — the user only writes from a PC with the
# SD inserted. If the partition is missing or corrupt, S99-app-launcher and
# the .NET app must continue to function with their bundled defaults.

DATA_DEV=/dev/mmcblk0p3
DATA_DIR=/data

start() {
    mkdir -p "$DATA_DIR"

    if [ ! -b "$DATA_DEV" ]; then
        echo "S10-mount-data: $DATA_DEV not present — skipping"
        return 0
    fi

    if mountpoint -q "$DATA_DIR" 2>/dev/null; then
        echo "S10-mount-data: $DATA_DIR already mounted — skipping"
        return 0
    fi

    if mount -t vfat -o ro,noatime "$DATA_DEV" "$DATA_DIR"; then
        echo "S10-mount-data: $DATA_DIR mounted (ro)"
    else
        echo "S10-mount-data: mount $DATA_DEV failed — continuing without /data"
    fi
}

stop() {
    if mountpoint -q "$DATA_DIR" 2>/dev/null; then
        umount "$DATA_DIR" || true
    fi
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac

exit 0
```

- [ ] **Step 2: Commit (mode bits set during sync)**

The script must be executable on the device; Buildroot preserves the mode of files in `rootfs-overlay/`. Since this is a Windows checkout and Git on Windows defaults `core.fileMode=false`, we set the mode via the post-build sync step (Task 1.7) — git stores it correctly thanks to `update-index --chmod=+x`:

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S10-mount-data
git update-index --chmod=+x buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S10-mount-data
git commit -m "feat(buildroot): add S10-mount-data to mount /data FAT32 partition"
```

---

## Task 1.4 — Author the `config.txt` and `README.txt` templates

**Files:**
- Create: `BRD/data/config.txt`
- Create: `BRD/data/README.txt`

These get copied into the FAT32 image at build time by `post-image.sh` (Task 1.6).

- [ ] **Step 1: Write the config template**

Write file `I:\Source\repos\RapidBeagle\buildroot\external\board\rapidbeagle\pocketbeagle\data\config.txt` with content:

```ini
# RapidBeagle config — edit on PC, insert SD, reboot.
#
# Format: KEY=value, one per line. Lines starting with '#' are comments.
# Whitespace around '=' is tolerated.

# ── WiFi ──
# Read by the .NET app via wpa_supplicant control socket. Not used by init.
wifi_ssid=
wifi_password=

# ── App binary (optional) ──
# If set and /data/<app_binary> is executable, S99-app-launcher runs it
# instead of the built-in /opt/app/rapidbeagle-app. Use this to deploy new
# app versions by copying a single binary onto this partition.
# app_binary=rapidbeagle-app
```

- [ ] **Step 2: Write the README**

Write file `I:\Source\repos\RapidBeagle\buildroot\external\board\rapidbeagle\pocketbeagle\data\README.txt` with content:

```
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
```

- [ ] **Step 3: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/data/config.txt buildroot/external/board/rapidbeagle/pocketbeagle/data/README.txt
git commit -m "feat(buildroot): config.txt + README.txt templates for /data partition"
```

---

## Task 1.5 — Update `genimage.cfg` to add the FAT32 data partition

**Files:**
- Modify: `BRD/genimage.cfg`

- [ ] **Step 1: Replace the file**

Use Edit tool with `replace_all=false`. Replace the existing content with:

`old_string` (full current content):
```
# genimage.cfg — RapidBeagle SD card layout
# Two partitions:
#   1. boot.vfat (FAT16, ~16 MB): MLO, u-boot.img, zImage, DTB, uEnv.txt
#   2. rootfs.ext4 (~512 MB): Linux rootfs + .NET 10 ASP.NET runtime + app slot

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
        size = 512M
    }
}
```

`new_string`:
```
# genimage.cfg — RapidBeagle SD card layout
# Three partitions:
#   1. boot.vfat (FAT16, ~16 MB):  MLO, u-boot.img, zImage, DTB, uEnv.txt
#   2. rootfs.ext4 (256 MB):       Linux rootfs + .NET 10 runtime (mounted RO via overlayfs)
#   3. data.vfat (FAT32, 256 MB):  user-editable; config.txt, app binary, etc.

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

image data.vfat {
    vfat {
        label = "RAPIDBEAGLE"
        # Files staged into BINARIES_DIR/data/ by post-image.sh
        file config.txt { image = "data/config.txt" }
        file README.txt  { image = "data/README.txt" }
    }
    size = 256M
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
        size = 256M
    }

    partition data {
        partition-type = 0xC
        image = "data.vfat"
    }
}
```

- [ ] **Step 2: Update `BR2_TARGET_ROOTFS_EXT2_SIZE` if present**

The rootfs.ext4 image is built by Buildroot using `BR2_TARGET_ROOTFS_EXT2_SIZE` from the defconfig. If the defconfig sets it to 512M (or larger than 256M), the image won't fit our new partition.

Read the defconfig:

```bash
grep -E '^BR2_TARGET_ROOTFS_EXT2_SIZE' "I:/Source/repos/RapidBeagle/buildroot/external/configs/rapidbeagle_pb_defconfig"
```

Expected: a line like `BR2_TARGET_ROOTFS_EXT2_SIZE="512M"`. If the value is `>256M` (or unset, defaulting to a value ≥256M), edit the defconfig:

`old_string`: (whatever the actual current size line is)
`new_string`: `BR2_TARGET_ROOTFS_EXT2_SIZE="256M"`

If the current value is already ≤256M, skip this step.

- [ ] **Step 3: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/genimage.cfg buildroot/external/configs/rapidbeagle_pb_defconfig
git commit -m "feat(buildroot): add FAT32 data partition, shrink rootfs to 256M"
```

---

## Task 1.6 — Update `post-image.sh` to stage FAT32 contents

**Files:**
- Modify: `BRD/post-image.sh`

- [ ] **Step 1: Replace the file**

Use Edit tool. Replace:

`old_string`:
```
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

`new_string`:
```
#!/usr/bin/env bash
# post-image.sh — runs after rootfs/kernel/U-Boot are built
#
# Responsibilities:
#   1. Copy uEnv.txt into the binaries dir so genimage picks it up
#   2. Stage the FAT32 data partition contents (config.txt, README.txt)
#   3. Run genimage to assemble sdcard.img from the partition layout

set -euo pipefail

BOARD_DIR="$(dirname "$(readlink -f "$0")")"
GENIMAGE_CFG="$BOARD_DIR/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# ── Step 1: Stage uEnv.txt for the boot partition ───────────────────────────
cp "$BOARD_DIR/uEnv.txt" "${BINARIES_DIR}/uEnv.txt"
echo "post-image: staged uEnv.txt"

# ── Step 2: Stage the FAT32 data partition contents ─────────────────────────
# genimage references these as "data/config.txt" and "data/README.txt"
# relative to BINARIES_DIR.
mkdir -p "${BINARIES_DIR}/data"
cp "$BOARD_DIR/data/config.txt" "${BINARIES_DIR}/data/config.txt"
cp "$BOARD_DIR/data/README.txt" "${BINARIES_DIR}/data/README.txt"
echo "post-image: staged data/{config.txt,README.txt}"

# ── Step 3: Run genimage ─────────────────────────────────────────────────────
rm -rf "${GENIMAGE_TMP}"
genimage \
    --rootpath   "${TARGET_DIR}"   \
    --tmppath    "${GENIMAGE_TMP}" \
    --inputpath  "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config     "${GENIMAGE_CFG}"

echo "post-image: sdcard.img ready at ${BINARIES_DIR}/sdcard.img"
```

- [ ] **Step 2: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh
git commit -m "feat(buildroot): stage data/ contents for FAT32 partition in post-image"
```

---

## Task 1.7 — Sync to WSL2, build, flash, verify

This task is the integration test for Phase 1.

- [ ] **Step 1: Sync the changed files to WSL2**

From Windows Git Bash:

```bash
cd "I:/Source/repos/RapidBeagle"
tar cf - buildroot/external | ssh -p 2222 root@localhost "cd /root/RapidBeagle && rm -rf buildroot/external && tar xf - && find buildroot/external -type f -exec sed -i 's/\r\$//' {} \; && chmod +x buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S10-mount-data"
```

The `chmod +x` is belt-and-suspenders since we're crossing a Windows filesystem.

- [ ] **Step 2: Force rebuild affected pieces**

The kernel must rebuild because we changed the fragment. The rootfs must rebuild because we added overlay files. genimage must run.

```bash
ssh -p 2222 root@localhost "cd ~/buildroot && rm -rf output/build/linux-* output/images/zImage output/images/rootfs.ext4 output/images/sdcard.img output/images/data.vfat output/images/boot.vfat && nohup make -j16 > /tmp/buildroot-build-$(date +%H%M).log 2>&1 &"
```

- [ ] **Step 3: Wait for completion**

Poll until done. Expected: 5–15 min.

```bash
ssh -p 2222 root@localhost "while pgrep -f 'make -j' >/dev/null; do sleep 30; tail -1 /tmp/buildroot-build*.log; done; ls -la /root/buildroot/output/images/sdcard.img"
```

Expected final output: a `sdcard.img` of approximately 528 MB (16 + 256 + 256).

- [ ] **Step 4: Verify the image hash and copy to dist/**

`build.sh` auto-copies on success, but if you ran `make` directly, copy manually:

```bash
scp -P 2222 root@localhost:/root/buildroot/output/images/sdcard.img "I:/Source/repos/RapidBeagle/dist/sdcard.img"
certutil -hashfile "I:/Source/repos/RapidBeagle/dist/sdcard.img" MD5
```

- [ ] **Step 5: Inspect partition table on the image (sanity check before flashing)**

```bash
ssh -p 2222 root@localhost "fdisk -l /root/buildroot/output/images/sdcard.img"
```

Expected output (sizes approximate):
```
Device                                    Boot    Start      End  Sectors  Size Id Type
/root/buildroot/output/images/sdcard.img1 *        2048    34815    32768   16M  c W95 FAT32 (LBA)
/root/buildroot/output/images/sdcard.img2         34816   559103   524288  256M 83 Linux
/root/buildroot/output/images/sdcard.img3        559104  1083391   524288  256M  c W95 FAT32 (LBA)
```

If only 2 partitions appear, genimage didn't pick up the new partition — check the `genimage.cfg` change.

- [ ] **Step 6: Flash and boot**

```bash
sudo ~/RapidBeagle/buildroot/scripts/flash-sdcard.sh /dev/sdX
```

Then power-cycle the device. From Git Bash on Windows:

```bash
ssh-keygen -R 192.168.7.2
```

- [ ] **Step 7: Verify on-device — partition mounted and overlayfs available**

Once the device is back up, via SSH:

```bash
ssh root@192.168.7.2 "cat /proc/filesystems | grep -E 'overlay|tmpfs' && ls -la /data && cat /data/config.txt | head -5 && mount | grep mmcblk0p3"
```

Expected:
- `nodev	tmpfs`
- `nodev	overlay`         ← key line; if absent, `CONFIG_OVERLAY_FS` didn't take
- A directory listing showing `config.txt` and `README.txt`
- The first 5 lines of the config template
- `/dev/mmcblk0p3 on /data type vfat (ro,noatime,...)`

If `overlay` is not in `/proc/filesystems`, debug:

```bash
ssh root@192.168.7.2 "zcat /proc/config.gz 2>/dev/null | grep OVERLAY || gunzip -c /proc/config.gz | grep OVERLAY || echo 'config.gz not present; check kernel build'"
```

(The kernel must have `CONFIG_IKCONFIG=y` for this — if not, just confirm by trying to mount: `mount -t overlay overlay -o lowerdir=/etc /tmp/x` should fail with EINVAL on missing args, not "filesystem not supported".)

- [ ] **Step 8: Phase 1 complete — commit any cleanup**

If the partition layout works and `/data` is readable, Phase 1 is done. No additional commit unless something needed fixing.

---

# Phase 2 — Read-only rootfs via overlay-init

This phase activates overlayfs. After this phase, `cat /proc/mounts | grep ' / '` shows `overlay`. The ext4 rootfs is read-only after boot.

## Task 2.1 — Author `/sbin/overlay-init`

**Files:**
- Create: `BRD/rootfs-overlay/sbin/overlay-init`

- [ ] **Step 1: Write the script**

Write file `I:\Source\repos\RapidBeagle\buildroot\external\board\rapidbeagle\pocketbeagle\rootfs-overlay\sbin\overlay-init` with content:

```sh
#!/bin/sh
# overlay-init — kernel `init=` PID 1 wrapper. Sets up overlayfs over the
# real ext4 rootfs and execs /sbin/init in the new overlay.
#
# Why: keeps /dev/mmcblk0p2 (the ext4 rootfs) read-only at runtime so we
# don't wear the SD card or risk corruption on power loss. Writes to /
# transparently land in a tmpfs upper layer in RAM.
#
# Boot path:
#   kernel mounts ext4 at / (rw)
#   kernel execs /sbin/overlay-init (this script) as PID 1
#   we mount tmpfs, build overlay, switch_root, exec /sbin/init
#   BusyBox init takes over normally; all S## scripts run unchanged.
#
# Failsafe: any error path execs /sbin/init directly so the device still
# boots in legacy RW mode (visible only via dmesg / serial).

set -e

# Sanity: we must be PID 1 for switch_root to work
[ "$$" = "1" ] || { echo "overlay-init: not PID 1 (pid=$$)"; exec /sbin/init "$@"; }

LOWER=/
TMPFS=/mnt
UPPER=$TMPFS/upper
WORK=$TMPFS/work
NEWROOT=$TMPFS/overlay
SIZE=128m

# Mount /proc + /sys briefly so mount -t can read the kernel's filesystem list.
# These are early; the real /proc and /sys mounts happen later in /etc/inittab.
mount -t proc     proc /proc 2>/dev/null || true
mount -t sysfs    sys  /sys  2>/dev/null || true

# Create tmpfs to hold upper + work layers (RAM-backed)
mount -t tmpfs -o "size=$SIZE,mode=755" tmpfs $TMPFS || {
    echo "overlay-init: tmpfs mount failed; booting RW"
    exec /sbin/init "$@"
}

mkdir -p $UPPER $WORK $NEWROOT

# Make the existing rootfs read-only (we're already running from it; the
# kernel allows this — running processes keep their file mappings).
mount -o remount,ro $LOWER || {
    echo "overlay-init: remount,ro failed; booting RW"
    umount $TMPFS 2>/dev/null
    exec /sbin/init "$@"
}

# Build the overlay
mount -t overlay overlay \
    -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" \
    $NEWROOT || {
    echo "overlay-init: overlay mount failed; remounting rw and booting"
    mount -o remount,rw $LOWER 2>/dev/null
    umount $TMPFS 2>/dev/null
    exec /sbin/init "$@"
}

# Make the tmpfs reachable from inside the new root so /mnt/upper /mnt/work
# stay accessible. Without this, after switch_root, /mnt would be the empty
# directory from the lower (ext4) layer.
mount --bind $TMPFS $NEWROOT/mnt || {
    echo "overlay-init: bind mount failed but overlay is up; pivoting anyway"
}

# Tear down the temporary /proc /sys before pivot — the real init will
# re-mount them under the new root.
umount /proc 2>/dev/null || true
umount /sys  2>/dev/null || true

# Pivot into the overlay; exec real init.
exec switch_root $NEWROOT /sbin/init "$@"
```

- [ ] **Step 2: Commit with executable bit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/sbin/overlay-init
git update-index --chmod=+x buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/sbin/overlay-init
git commit -m "feat(buildroot): add /sbin/overlay-init PID 1 wrapper for read-only rootfs"
```

---

## Task 2.2 — Add `init=/sbin/overlay-init` to kernel cmdline

**Files:**
- Modify: `BRD/uEnv.txt`

- [ ] **Step 1: Edit `uEnv.txt`**

Append `init=/sbin/overlay-init` to the bootargs in the `uenvcmd` line. Use Edit tool:

`old_string`:
```
# Boot command: load kernel + DTB, set bootargs, jump
uenvcmd=load mmc ${mmcdev}:1 ${loadaddr} zImage; load mmc ${mmcdev}:1 ${fdtaddr} ${fdtfile}; setenv bootargs root=${mmcroot} rootfstype=${mmcrootfstype} rootwait ${optargs} console=${console}; bootz ${loadaddr} - ${fdtaddr}
```

`new_string`:
```
# Boot command: load kernel + DTB, set bootargs, jump.
# init=/sbin/overlay-init wraps PID 1 to set up overlayfs RO rootfs (see
# rootfs-overlay/sbin/overlay-init). Removing it boots in legacy RW mode.
uenvcmd=load mmc ${mmcdev}:1 ${loadaddr} zImage; load mmc ${mmcdev}:1 ${fdtaddr} ${fdtfile}; setenv bootargs root=${mmcroot} rootfstype=${mmcrootfstype} rootwait init=/sbin/overlay-init ${optargs} console=${console}; bootz ${loadaddr} - ${fdtaddr}
```

- [ ] **Step 2: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/uEnv.txt
git commit -m "feat(buildroot): boot with init=/sbin/overlay-init for read-only rootfs"
```

---

## Task 2.3 — Sync, rebuild, flash, verify

- [ ] **Step 1: Sync changed files to WSL2**

```bash
cd "I:/Source/repos/RapidBeagle"
tar cf - buildroot/external | ssh -p 2222 root@localhost "cd /root/RapidBeagle && rm -rf buildroot/external && tar xf - && find buildroot/external -type f -exec sed -i 's/\r\$//' {} \; && chmod +x buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S* buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/sbin/overlay-init"
```

- [ ] **Step 2: Incremental rebuild**

No kernel changes this phase — just rootfs and image.

```bash
ssh -p 2222 root@localhost "cd ~/buildroot && rm -f output/images/sdcard.img output/images/rootfs.ext4 output/images/data.vfat output/images/boot.vfat && nohup make -j16 > /tmp/buildroot-build-$(date +%H%M).log 2>&1 &"
```

- [ ] **Step 3: Wait, copy, flash**

```bash
ssh -p 2222 root@localhost "while pgrep -f 'make -j' >/dev/null; do sleep 15; done; ls -la /root/buildroot/output/images/sdcard.img"
scp -P 2222 root@localhost:/root/buildroot/output/images/sdcard.img "I:/Source/repos/RapidBeagle/dist/sdcard.img"
sudo ~/RapidBeagle/buildroot/scripts/flash-sdcard.sh /dev/sdX
```

Power-cycle, `ssh-keygen -R 192.168.7.2`.

- [ ] **Step 4: Verify overlayfs is active**

If SSH does not come up within 30s, switch to serial via COM6 (`pb-serial.py`) and inspect dmesg for overlay-init failures.

```bash
ssh root@192.168.7.2 "mount | grep -E ' / | /mnt' && cat /proc/mounts | head -5 && cat /proc/cmdline"
```

Expected:
- `overlay on / type overlay (rw,relatime,lowerdir=/,upperdir=/mnt/upper,workdir=/mnt/work)`
- `tmpfs on /mnt type tmpfs ...` (or similar; the bind from /mnt/overlay/mnt)
- `/proc/cmdline` contains `init=/sbin/overlay-init`

- [ ] **Step 5: Verify writes are ephemeral**

```bash
ssh root@192.168.7.2 "echo testmarker > /reboot-test-marker && cat /reboot-test-marker && sync && reboot"
```

Wait for the device to come back, then:

```bash
ssh-keygen -R 192.168.7.2
ssh root@192.168.7.2 "ls -la /reboot-test-marker 2>&1"
```

Expected: `ls: /reboot-test-marker: No such file or directory` — the file lived in tmpfs upper, gone after reboot.

- [ ] **Step 6: Verify ext4 is RO**

```bash
ssh root@192.168.7.2 "mount | grep mmcblk0p2"
```

Expected: should show `ro` in the mount options. If you don't see ext4 in `mount` output, that's normal — the lowerdir is `/` (the original root), and after switch_root the original root may not appear in /proc/mounts directly. The proof is that writes via the overlay don't reach the SD: `dd if=/dev/zero of=/dev/null count=1` works, but writes to `/dev/mmcblk0p2` directly fail with EROFS.

A more direct check:

```bash
ssh root@192.168.7.2 "dd if=/dev/zero of=/dev/mmcblk0p2 bs=1 count=1 seek=0 2>&1 | head -3"
```

Expected: `dd: writing to '/dev/mmcblk0p2': Read-only file system` (or similar).

- [ ] **Step 7: Phase 2 complete**

If overlay is mounted at `/`, writes are ephemeral, and ext4 is RO at the block layer, Phase 2 is done. No additional commit unless something needed fixing.

If overlay-init failed and the device booted RW (legacy fallback), check `dmesg | grep overlay-init` via SSH or serial and fix the script.

---

# Phase 3 — USB networking auto-detect

This phase makes `usb0` work plug-and-play with both PC (static IP) and Android (DHCP). Three files change; no kernel rebuild needed.

## Task 3.1 — Verify `udhcpc` default script is present

**Files:**
- Inspect: device's `/usr/share/udhcpc/default.script`

- [ ] **Step 1: Check on the existing image**

```bash
ssh root@192.168.7.2 "ls -la /usr/share/udhcpc/default.script && file /usr/share/udhcpc/default.script"
```

Expected: file exists, ~3 KB, "POSIX shell script". If missing, BusyBox's udhcpc package was built without it — Buildroot's `BR2_PACKAGE_BUSYBOX` includes it by default. If absent, add to `BRD/rootfs-overlay/usr/share/udhcpc/default.script` (BusyBox source ships it; copy from `~/buildroot/output/build/busybox-*/examples/udhcp/simple.script` or the Buildroot equivalent).

If the script is present, no action needed for this task.

---

## Task 3.2 — Update `S39-usb-gadget` for DHCP-then-static

**Files:**
- Modify: `BRD/rootfs-overlay/etc/init.d/S39-usb-gadget` (lines 99–106)

- [ ] **Step 1: Replace the `ifup usb0` block with DHCP-then-static**

Use Edit tool:

`old_string`:
```
    # Bring the resulting usb0 interface up immediately. The interface only
    # appears AFTER UDC binding above, so /etc/network/interfaces 'allow-hotplug'
    # does not fire (the kernel does not emit a hotplug event for configfs-
    # created interfaces — it just adds them). Trigger ifup explicitly.
    if [ -e /sys/class/net/usb0 ]; then
        ifup usb0 >/dev/null 2>&1 || true
        echo "S39-usb-gadget: usb0 brought up"
    fi
}
```

`new_string`:
```
    # Bring usb0 up. Try DHCP for 3 seconds (Android phone hosting); if that
    # fails (PC connection — no DHCP server on the host), fall back to a
    # static 192.168.7.2/24. Either way, the resolved IP is written to
    # /run/usb0.ip for the .NET app to expose however it likes.
    if [ -e /sys/class/net/usb0 ]; then
        ip link set usb0 up
        if udhcpc -i usb0 -t 1 -T 3 -n -q \
                  -s /usr/share/udhcpc/default.script >/dev/null 2>&1; then
            ip -4 addr show usb0 | awk '/inet /{print $2}' | cut -d/ -f1 \
                > /run/usb0.ip
            echo "S39-usb-gadget: usb0 DHCP success ($(cat /run/usb0.ip))"
        else
            ip addr add 192.168.7.2/24 dev usb0 2>/dev/null || true
            echo 192.168.7.2 > /run/usb0.ip
            echo "S39-usb-gadget: usb0 DHCP timeout, static 192.168.7.2"
        fi
    fi
}
```

- [ ] **Step 2: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S39-usb-gadget
git commit -m "feat(buildroot): S39 — auto-detect DHCP (Android) vs static (PC) on usb0"
```

---

## Task 3.3 — Remove `usb0` stanza from `/etc/network/interfaces`

**Files:**
- Modify: `BRD/rootfs-overlay/etc/network/interfaces`

- [ ] **Step 1: Edit the file**

Use Edit tool:

`old_string`:
```
# /etc/network/interfaces — RapidBeagle networking
# usb0:  USB gadget — static 192.168.7.2/24 (host expected at 192.168.7.1)
# eth0:  ethernet (none on PocketBeagle, but config kept for general AM335x)
# wlan0: NOT brought up here. The dotnet app drives wpa_supplicant via control socket.

auto lo
iface lo inet loopback

# usb0 (USB gadget) — brought up when the kernel enumerates the gadget device.
# allow-hotplug makes ifup wait for the kernel uevent rather than failing
# at boot if the gadget driver isn't ready yet.
# NOTE: do NOT also use 'auto usb0' here — ifup treats both directives on
# the same interface as a duplicate option and aborts.
allow-hotplug usb0
iface usb0 inet static
    address 192.168.7.2
    netmask 255.255.255.0

# eth0 — DHCP if interface is present (no eth0 on stock PocketBeagle, but
# kept here as a no-op for general AM335x boards).
allow-hotplug eth0
iface eth0 inet dhcp
```

`new_string`:
```
# /etc/network/interfaces — RapidBeagle networking
# usb0:  managed by S39-usb-gadget (DHCP-then-static), NOT here.
# eth0:  ethernet (none on PocketBeagle, but config kept for general AM335x)
# wlan0: NOT brought up here. The dotnet app drives wpa_supplicant via control socket.

auto lo
iface lo inet loopback

# eth0 — DHCP if interface is present (no eth0 on stock PocketBeagle, but
# kept here as a no-op for general AM335x boards).
allow-hotplug eth0
iface eth0 inet dhcp
```

- [ ] **Step 2: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/network/interfaces
git commit -m "feat(buildroot): drop usb0 stanza from interfaces (now managed by S39)"
```

---

## Task 3.4 — Sync, rebuild, flash, verify (PC mode + Android mode)

- [ ] **Step 1: Sync, rebuild, flash**

```bash
cd "I:/Source/repos/RapidBeagle"
tar cf - buildroot/external | ssh -p 2222 root@localhost "cd /root/RapidBeagle && rm -rf buildroot/external && tar xf - && find buildroot/external -type f -exec sed -i 's/\r\$//' {} \; && chmod +x buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S* buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/sbin/overlay-init"

ssh -p 2222 root@localhost "cd ~/buildroot && rm -f output/images/sdcard.img output/images/rootfs.ext4 && nohup make -j16 > /tmp/buildroot-build-$(date +%H%M).log 2>&1 &"

ssh -p 2222 root@localhost "while pgrep -f 'make -j' >/dev/null; do sleep 15; done"

scp -P 2222 root@localhost:/root/buildroot/output/images/sdcard.img "I:/Source/repos/RapidBeagle/dist/sdcard.img"
sudo ~/RapidBeagle/buildroot/scripts/flash-sdcard.sh /dev/sdX
```

Power-cycle, `ssh-keygen -R 192.168.7.2`.

- [ ] **Step 2: Verify static fallback (PC mode)**

Connect to a PC (the default scenario). After boot:

```bash
ssh root@192.168.7.2 "ip -4 addr show usb0 && cat /run/usb0.ip && logread | grep S39-usb-gadget | tail -5"
```

Expected:
- `inet 192.168.7.2/24` on `usb0`
- `/run/usb0.ip` contains `192.168.7.2`
- Last log line: `S39-usb-gadget: usb0 DHCP timeout, static 192.168.7.2`

Boot time penalty: ~3 seconds vs. previous Phase 2 measurement (acceptable).

- [ ] **Step 3: Verify DHCP success (Android mode)**

Disconnect from PC. Plug into an Android phone with USB tethering enabled. The phone should hand the device an IP in its USB-tethering range (commonly `192.168.42.0/24` on Android, but varies).

You won't be able to SSH to the device from your PC at this point (it's now on the phone's USB network, not yours). Two ways to verify:

**Option A — Use serial (COM6) while the device is connected to Android.** Plug in the USB-to-TTL adapter to the PocketBeagle's serial header (`P2.7`/`P2.8` etc.; the existing setup's COM6) — note this requires a way to power the PB while the USB OTG is connected to Android (typically via the serial adapter's 5V pin or a separate barrel-jack supply). Then:

```bash
python "C:\Users\shawn\AppData\Local\Temp\pb-serial.py" "ip -4 addr show usb0; cat /run/usb0.ip; logread | grep S39-usb-gadget | tail -5"
```

Expected:
- `inet 192.168.42.x/24` (or similar non-`192.168.7.2` address)
- `/run/usb0.ip` contains the same address
- Last log: `S39-usb-gadget: usb0 DHCP success (192.168.42.x)`

**Option B — Skip live verification, accept based on logs.** If you boot the device on the PC first and confirm static works, then cleanly switch to Android, the change is small and self-contained. If `/run/usb0.ip` shows `192.168.7.2` (static), DHCP is taking the timeout path — verify behavior end-to-end when you next have the Android setup ready.

- [ ] **Step 4: Phase 3 complete**

---

# Phase 4 — App launcher reads from `/data`

The final logic change: `S99-app-launcher` searches `/data/<app_binary>` first (config-driven), then `/data/rapidbeagle-app`, then the baked-in `/opt/app/rapidbeagle-app`.

## Task 4.1 — Update `S99-app-launcher`

**Files:**
- Modify: `BRD/rootfs-overlay/etc/init.d/S99-app-launcher`

- [ ] **Step 1: Replace the `start()` function**

Use Edit tool:

`old_string`:
```
APP=/opt/app/rapidbeagle-app
PIDFILE=/run/app.pid
LOGFILE=/var/log/app.log
BOOT_FLAG=/run/boot-complete

start() {
    # Record how long boot took (kernel start -> this point in init).
    # /proc/uptime line: "<seconds_since_boot> <seconds_idle>"
    read UPTIME _ < /proc/uptime
    echo "boot_to_userspace_seconds: $UPTIME" > /run/boot-time.log
    echo "boot_kernel_release: $(uname -r)" >> /run/boot-time.log
    echo "boot_date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> /run/boot-time.log
    echo "S99-app-launcher: kernel-to-userspace took ${UPTIME}s"

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
```

`new_string`:
```
APP_FALLBACK=/opt/app/rapidbeagle-app
DATA_DEFAULT=/data/rapidbeagle-app
PIDFILE=/run/app.pid
LOGFILE=/var/log/app.log
BOOT_FLAG=/run/boot-complete
CONFIG=/data/config.txt

# Resolve which binary to run. Order:
#   1. /data/<app_binary> if config.txt sets app_binary= and the file is exec.
#   2. /data/rapidbeagle-app if it exists and is exec.
#   3. /opt/app/rapidbeagle-app (baked-in fallback).
resolve_app() {
    if [ -r "$CONFIG" ]; then
        BIN=$(sed -n 's/^[[:space:]]*app_binary[[:space:]]*=[[:space:]]*//p' "$CONFIG" | head -1 | tr -d '\r')
        if [ -n "$BIN" ] && [ -x "/data/$BIN" ]; then
            echo "/data/$BIN"
            return 0
        fi
    fi
    if [ -x "$DATA_DEFAULT" ]; then
        echo "$DATA_DEFAULT"
        return 0
    fi
    if [ -x "$APP_FALLBACK" ]; then
        echo "$APP_FALLBACK"
        return 0
    fi
    return 1
}

start() {
    # Record how long boot took (kernel start -> this point in init).
    # /proc/uptime line: "<seconds_since_boot> <seconds_idle>"
    read UPTIME _ < /proc/uptime
    echo "boot_to_userspace_seconds: $UPTIME" > /run/boot-time.log
    echo "boot_kernel_release: $(uname -r)" >> /run/boot-time.log
    echo "boot_date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> /run/boot-time.log
    echo "S99-app-launcher: kernel-to-userspace took ${UPTIME}s"

    # Mark boot complete so the heartbeat transitions to "boot done"
    touch "$BOOT_FLAG"

    APP=$(resolve_app)
    if [ -z "$APP" ]; then
        echo "S99-app-launcher: no app found in /data or /opt/app — skipping"
        return 0
    fi

    # Make sure /var/log exists (it's tmpfs, recreated each boot)
    mkdir -p /var/log

    # Launch the app in background, capture PID
    "$APP" >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "S99-app-launcher: started $APP (pid $(cat "$PIDFILE"))"
}
```

- [ ] **Step 2: Commit**

```bash
cd "I:/Source/repos/RapidBeagle"
git add buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S99-app-launcher
git commit -m "feat(buildroot): S99 — search /data/{app_binary,rapidbeagle-app} then /opt/app"
```

---

## Task 4.2 — Sync, rebuild, flash, verify

- [ ] **Step 1: Sync, rebuild, flash**

```bash
cd "I:/Source/repos/RapidBeagle"
tar cf - buildroot/external | ssh -p 2222 root@localhost "cd /root/RapidBeagle && rm -rf buildroot/external && tar xf - && find buildroot/external -type f -exec sed -i 's/\r\$//' {} \; && chmod +x buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/etc/init.d/S* buildroot/external/board/rapidbeagle/pocketbeagle/rootfs-overlay/sbin/overlay-init"

ssh -p 2222 root@localhost "cd ~/buildroot && rm -f output/images/sdcard.img output/images/rootfs.ext4 && nohup make -j16 > /tmp/buildroot-build-$(date +%H%M).log 2>&1 &"

ssh -p 2222 root@localhost "while pgrep -f 'make -j' >/dev/null; do sleep 15; done"

scp -P 2222 root@localhost:/root/buildroot/output/images/sdcard.img "I:/Source/repos/RapidBeagle/dist/sdcard.img"
sudo ~/RapidBeagle/buildroot/scripts/flash-sdcard.sh /dev/sdX
```

Power-cycle, `ssh-keygen -R 192.168.7.2`.

- [ ] **Step 2: Verify fallback path (no app on /data)**

```bash
ssh root@192.168.7.2 "logread | grep S99-app-launcher && cat /run/boot-time.log"
```

Expected: log shows `started /opt/app/rapidbeagle-app` (if you have one baked in) or `no app found in /data or /opt/app`. Both are correct since `/data` doesn't have an app yet.

- [ ] **Step 3: Verify `/data` deploy path**

Build a small test app (any executable will do — even a 5-line shell script). On the WSL2 host:

```bash
cat > /tmp/rapidbeagle-app <<'EOF'
#!/bin/sh
echo "hello from /data/rapidbeagle-app at $(date)" > /run/test-app-marker
sleep 3600
EOF
chmod +x /tmp/rapidbeagle-app
```

Mount the data partition on the WSL2 host (since the SD is in the host's reader after flashing):

```bash
sudo mkdir -p /mnt/rapidbeagle-data
sudo mount /dev/sdX3 /mnt/rapidbeagle-data
sudo cp /tmp/rapidbeagle-app /mnt/rapidbeagle-data/
sudo umount /mnt/rapidbeagle-data
```

Re-insert SD into the device, power-cycle. Then:

```bash
ssh-keygen -R 192.168.7.2
ssh root@192.168.7.2 "cat /run/test-app-marker && logread | grep S99-app-launcher | tail -3"
```

Expected:
- `hello from /data/rapidbeagle-app at <timestamp>`
- Log shows `started /data/rapidbeagle-app`

- [ ] **Step 4: Verify `app_binary=` config override**

Add a second binary `/tmp/myapp.sh` and reference it in config.txt:

```bash
cat > /tmp/myapp.sh <<'EOF'
#!/bin/sh
echo "myapp via app_binary=" > /run/test-app-marker
sleep 3600
EOF
chmod +x /tmp/myapp.sh

sudo mount /dev/sdX3 /mnt/rapidbeagle-data
sudo cp /tmp/myapp.sh /mnt/rapidbeagle-data/
# Edit config.txt: uncomment app_binary= and set to myapp.sh
sudo sed -i 's/^# app_binary=rapidbeagle-app/app_binary=myapp.sh/' /mnt/rapidbeagle-data/config.txt
sudo umount /mnt/rapidbeagle-data
```

Re-insert, boot, then:

```bash
ssh-keygen -R 192.168.7.2
ssh root@192.168.7.2 "cat /run/test-app-marker && logread | grep S99-app-launcher | tail -3"
```

Expected:
- `myapp via app_binary=`
- Log shows `started /data/myapp.sh`

- [ ] **Step 5: Phase 4 complete**

---

# Phase 5 — Final acceptance checks

Run through the spec's acceptance criteria one by one. Each item must pass.

## Task 5.1 — Run all acceptance criteria

- [ ] **Step 1: Read-only rootfs** — `ssh root@192.168.7.2 "cat /proc/mounts | grep ' / '"` shows `overlay`. Writes to `/` succeed at runtime; verify they vanish across reboot:

```bash
ssh root@192.168.7.2 "touch /reboot-test && ls -la /reboot-test && reboot"
sleep 20
ssh-keygen -R 192.168.7.2
ssh root@192.168.7.2 "ls -la /reboot-test 2>&1 | grep -E 'No such|reboot-test'"
```

Expected on second invocation: `No such file or directory`.

- [ ] **Step 2: Data partition mounted RO** — `ssh root@192.168.7.2 "mount | grep /data"` shows `vfat ro`.

- [ ] **Step 3: config.txt readable** — `ssh root@192.168.7.2 "cat /data/config.txt"` returns the template.

- [ ] **Step 4: PC connection static IP** — `ssh root@192.168.7.2 "cat /run/usb0.ip"` returns `192.168.7.2` after a PC boot.

- [ ] **Step 5: Android connection DHCP IP** — connect to Android phone (USB tethering on); via serial: `python pb-serial.py "cat /run/usb0.ip"` returns a non-`192.168.7.2` address.

- [ ] **Step 6: App-from-data deploy** — Phase 4 Task 4.2 Steps 3-4 already exercised this.

- [ ] **Step 7: SD removable after boot** — `ssh root@192.168.7.2 "cat /run/usb0.ip"` once, then physically pull the SD card. SSH session stays alive (modulo reads from disk that must hit cache). New shells / process exec from disk fails — that's expected.

```bash
ssh root@192.168.7.2 "cat /run/usb0.ip"
# pull SD here
ssh root@192.168.7.2 "cat /run/usb0.ip"   # this still works (already in memory)
ssh root@192.168.7.2 "uptime"             # may or may not work depending on what's cached
```

- [ ] **Step 8: Boot time within budget** — measure from PowerShell:

```powershell
$s=Get-Date; do { ssh -o ConnectTimeout=1 -o BatchMode=yes root@192.168.7.2 "true" 2>$null } until ($LASTEXITCODE -eq 0); "{0:N2}s" -f ((Get-Date)-$s).TotalSeconds
```

Expected: ≤13s end-to-end power-on → SSH (≤10s today + ~3s DHCP timeout penalty in PC mode).

- [ ] **Step 9: Update HANDOFF / journal docs**

Add a section to `docs/BUILD_JOURNAL.md` under "Pitfall log" if you hit anything new during this implementation. Update `docs/HANDOFF_NEXT_CHAT.md` "What's working" table with:

- `Read-only rootfs (overlayfs + tmpfs upper)` — ✅
- `Data partition (FAT32, /data)` — ✅
- `usb0 plug-and-play (DHCP fallback to static)` — ✅
- `App deploy via /data` — ✅

```bash
cd "I:/Source/repos/RapidBeagle"
git add docs/HANDOFF_NEXT_CHAT.md docs/BUILD_JOURNAL.md
git commit -m "docs: overlayfs + data partition + usb0 auto-detect shipped"
```

- [ ] **Step 10: Final flashable image**

The image at `I:\Source\repos\RapidBeagle\dist\sdcard.img` is the deliverable. Record its MD5:

```bash
certutil -hashfile "I:/Source/repos/RapidBeagle/dist/sdcard.img" MD5
```

Note it in the handoff doc.

---

# Notes for the implementer

- **Build cache traps.** If a rootfs-overlay file change doesn't appear on the device, force rebuild that piece: `ssh -p 2222 root@localhost "cd ~/buildroot && rm -f output/images/rootfs.ext4 output/images/sdcard.img && make -j16"`. Buildroot's `rootfs-overlay` is regenerated only when the rootfs target rebuilds.
- **Mode bits via Windows checkout.** Git on Windows defaults `core.fileMode=false`. Use `git update-index --chmod=+x <path>` whenever you add a new shell script under `rootfs-overlay/`. The post-sync `chmod +x` in the tar pipe is a backstop.
- **CRLF line endings.** The sync command's `find ... sed -i 's/\r$//'` is essential — Windows checkouts often have CRLF and BusyBox ash will fail with `: not found` errors that look bizarre.
- **Recovery.** If a flashed image refuses to boot, you can always reflash a known-good image from `I:\Source\repos\RapidBeagle\dist\sdcard.img` history (git LFS or just an out-of-band backup). The pre-overlayfs image MD5 from the handoff (`fa3311cd7365ba051602c0d05a70c22e`) is your last-known-good snapshot.
- **Failsafe paths.** Each phase preserves a fallback: Phase 1 doesn't activate overlay (data partition is additive). Phase 2's overlay-init falls back to `exec /sbin/init` on any error (legacy RW mode). Phase 3's S39 falls back to static if DHCP fails. Phase 4's launcher falls back to `/opt/app/`. The device should always boot into something.
