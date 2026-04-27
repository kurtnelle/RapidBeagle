# RapidBeagle — Overlayfs Read-Only Rootfs + Data Partition

**Date:** 2026-04-26
**Status:** Design approved, ready for implementation plan
**Target:** PocketBeagle (TI AM335x, ARMv7 Cortex-A8) running our Buildroot image with kernel 6.6.30 and BusyBox init

---

## Goals

1. **Zero SD writes after boot.** Power-cut safe. SD card may be physically removed after boot completes without filesystem damage.
2. **User-editable config volume.** A FAT32 partition the user edits on a PC (Windows/Mac/Linux) and the device reads at boot. Holds `config.txt` (WiFi credentials, app settings) and optionally the app binary.
3. **Plug-and-play USB networking.** `usb0` works against a PC (static `192.168.7.2`) and against an Android phone (DHCP client) without changing the SD config.

## Non-goals

- Persisting writes across reboots from the device side (writes to `/` go to a RAM-only tmpfs and are lost on reboot — by design).
- Resizing the data partition automatically on first boot. The image ships with a fixed 256 MB data partition; the user resizes manually with `parted`/`Disks` if they want more space.
- Discovering the device's IP on Android automatically. The IP is written to `/run/usb0.ip` for the .NET app to expose however it likes (mDNS, log, etc.) — that's out of scope for this spec.

---

## Architecture overview

```
SD card layout
[ p1: boot   FAT16 16MB ]   ← bootloader + kernel (unchanged)
[ p2: rootfs ext4  256MB]   ← OS image, mounted read-only after boot
[ p3: data   FAT32 256MB]   ← user-editable, mounted RO at /data

Boot sequence (kernel cmdline: init=/sbin/overlay-init)
  kernel → /sbin/overlay-init (PID 1)
       → mount tmpfs at /mnt (RAM upper layer)
       → mount overlayfs (lower=/, upper=/mnt/upper, work=/mnt/work) at /mnt/overlay
       → bind-mount tmpfs into overlay so /mnt is reachable post-switch
       → exec switch_root /mnt/overlay /sbin/init
  /sbin/init (BusyBox) → S## scripts run normally (rootfs is now overlay)
       → S10-mount-data       mounts /dev/mmcblk0p3 RO at /data
       → S39-usb-gadget       creates gadget, tries DHCP (3s), falls back to static
       → S98-pb-heartbeat     LED state machine
       → S99-app-launcher     reads /data/config.txt, launches app
```

Writes to `/`, `/var`, `/tmp`, `/run`, `/etc` all land transparently in the tmpfs upper layer. The ext4 partition is read-only from the moment overlay-init finishes.

---

## Section 1 — Partition layout

**File:** `buildroot/external/board/rapidbeagle/pocketbeagle/genimage.cfg`

Three partitions on a ~528 MB total image (same size as today):

| # | Mount | FS    | Size  | Contents                                          |
|---|-------|-------|-------|---------------------------------------------------|
| 1 | (boot)| FAT16 | 16 MB | MLO, u-boot.img, zImage, DTB, uEnv.txt            |
| 2 | `/`   | ext4  | 256 MB| OS rootfs (mounted read-only after overlay-init)  |
| 3 | `/data` | FAT32 | 256 MB | User-editable: `config.txt`, app binaries, README |

The data partition is pre-populated at build time by `post-image.sh` using `mcopy`:

- `config.txt` — commented template
- `README.txt` — short note explaining the partition

Rationale: rootfs uses ~32 MB today; 256 MB is 8× headroom and frees the other 256 MB for user space without growing the image.

---

## Section 2 — Overlayfs read-only rootfs

### `/sbin/overlay-init`

New script (BusyBox ash, executable, runs as PID 1). Lives in `rootfs-overlay/sbin/overlay-init`.

Pseudocode:

```sh
#!/bin/sh
# Mount tmpfs to hold upper + work layers (RAM-backed)
mount -t tmpfs -o size=128m,mode=755 tmpfs /mnt
mkdir -p /mnt/upper /mnt/work /mnt/overlay

# Make the existing rootfs read-only (we're already running from it)
mount -o remount,ro /

# Build the overlay
mount -t overlay overlay \
    -o lowerdir=/,upperdir=/mnt/upper,workdir=/mnt/work \
    /mnt/overlay

# Make the tmpfs reachable from inside the new root
mount --bind /mnt /mnt/overlay/mnt

# Pivot into the overlay; exec real init
exec switch_root /mnt/overlay /sbin/init
```

If any step fails, the script falls back to `exec /sbin/init` directly (degraded mode: rootfs is RW as today). This guarantees the device boots even if overlayfs fails — visible only via dmesg / serial console.

### `uEnv.txt`

Add `init=/sbin/overlay-init` to the kernel cmdline. The rest of the existing args (`silent=1`, `quiet`, `loglevel=3`, console, root=, etc.) are preserved.

### Kernel config — verify

`linux-fragment.config` must contain:

```
CONFIG_OVERLAY_FS=y
CONFIG_TMPFS=y
```

The tmpfs is universal in Linux; overlayfs is in mainline since 3.18 and present in the 6.6.x kernel we're using. Both should already be present (overlayfs may need to be added). The implementation plan must verify and add if missing.

### Tmpfs sizing

128 MB cap. Actual RAM usage scales with writes — at idle nothing writes, so cost is near-zero. The 128 MB ceiling protects against runaway log writes filling RAM.

---

## Section 3 — Data partition + config.txt

### `S10-mount-data`

New init script. Runs before `S39-usb-gadget` (so the gadget config is available if anything ever needs it) and before `S99-app-launcher`.

Pseudocode:

```sh
#!/bin/sh
DATA_DEV=/dev/mmcblk0p3
DATA_DIR=/data
mkdir -p "$DATA_DIR"
if [ -b "$DATA_DEV" ]; then
    mount -t vfat -o ro,noatime "$DATA_DEV" "$DATA_DIR" \
        || logger -t mount-data "FAILED to mount $DATA_DEV"
else
    logger -t mount-data "$DATA_DEV not present; skipping"
fi
```

Mount is read-only on the device side. The user only writes from a PC (with the SD inserted there).

### `/data/config.txt` format

Plain `KEY=value`, `#` for comments, blank lines OK. Must be parseable by:

- BusyBox ash: `grep -E '^wifi_ssid=' /data/config.txt | cut -d= -f2-`
- .NET: trivial split-on-first-`=` per line

Initial template:

```ini
# RapidBeagle config — edit on PC, insert SD, reboot.

# WiFi credentials (read by your application via wpa_supplicant control socket)
wifi_ssid=
wifi_password=

# App binary (optional). If unset, the launcher tries /data/rapidbeagle-app,
# then falls back to /opt/app/rapidbeagle-app baked into the image.
# app_binary=rapidbeagle-app
```

Init scripts do not parse WiFi credentials — that's the .NET app's job. The init scripts only need `app_binary` (read by S99-app-launcher).

### Mount point in rootfs

Add an empty `/data` directory to the rootfs overlay so the mount point exists in the read-only ext4. Achieved by adding a `.gitkeep` (or empty placeholder) under `rootfs-overlay/data/`.

---

## Section 4 — USB network auto-detect

### `S39-usb-gadget` changes

Today the script ends with `ifup usb0` (static config from `/etc/network/interfaces`). Replace with:

```sh
ip link set usb0 up

# Try DHCP for 3 seconds, no retries
if udhcpc -i usb0 -t 1 -T 3 -n -q -s /usr/share/udhcpc/default.script 2>&1 \
        | logger -t usb0-dhcp; then
    # DHCP success — record the IP for the app to consume
    ip -4 addr show usb0 | awk '/inet /{print $2}' | cut -d/ -f1 > /run/usb0.ip
    logger -t usb0 "DHCP success: $(cat /run/usb0.ip)"
else
    # DHCP failed (no server, e.g. PC connection) — static fallback
    ip addr add 192.168.7.2/24 dev usb0
    echo 192.168.7.2 > /run/usb0.ip
    logger -t usb0 "DHCP timeout, using static 192.168.7.2"
fi
```

`udhcpc` flags:
- `-t 1` — single DISCOVER, no retransmit
- `-T 3` — 3-second timeout per attempt
- `-n` — exit if no lease, do not background
- `-q` — quit after obtaining lease (don't keep running)
- `-s` — explicit path to the default script (BusyBox installs it at `/usr/share/udhcpc/default.script`)

### `/etc/network/interfaces`

Remove the `iface usb0` stanza entirely (it's now managed by S39). Keep `lo` and `eth0`:

```
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp
```

### IP discovery file

`/run/usb0.ip` contains the resolved IP — either the DHCP-assigned one or `192.168.7.2`. The .NET app reads this and exposes it however it wants. `/run` is on the tmpfs overlay (writable, ephemeral, perfect for this).

---

## Section 5 — App launcher

### `S99-app-launcher` changes

Pseudocode:

```sh
#!/bin/sh
APP=""

# Resolve app_binary= from /data/config.txt if present
if [ -r /data/config.txt ]; then
    BIN=$(sed -n 's/^[[:space:]]*app_binary[[:space:]]*=[[:space:]]*//p' /data/config.txt | head -1)
    [ -n "$BIN" ] && [ -x "/data/$BIN" ] && APP="/data/$BIN"
fi

# Fallbacks: /data/rapidbeagle-app, then /opt/app/rapidbeagle-app
[ -z "$APP" ] && [ -x /data/rapidbeagle-app ]    && APP=/data/rapidbeagle-app
[ -z "$APP" ] && [ -x /opt/app/rapidbeagle-app ] && APP=/opt/app/rapidbeagle-app

# Record boot time (unchanged from today)
echo "boot_to_userspace_seconds=$(awk '{print $1}' /proc/uptime)" > /run/boot-time.log
echo "boot_to_userspace_seconds=$(awk '{print $1}' /proc/uptime)" > /run/boot-complete

if [ -n "$APP" ]; then
    logger -t app-launcher "starting $APP"
    exec "$APP" >> /var/log/app.log 2>&1
else
    logger -t app-launcher "no app found in /data or /opt/app"
fi
```

The heartbeat handoff to S98 (the `/run/boot-complete` write) is preserved.

---

## File inventory

| File                                                                  | Action  | Notes                                                                  |
|-----------------------------------------------------------------------|---------|------------------------------------------------------------------------|
| `buildroot/external/board/rapidbeagle/pocketbeagle/genimage.cfg`      | edit    | Add p3 (FAT32 256 MB), shrink p2 from 512 MB to 256 MB                 |
| `buildroot/external/board/rapidbeagle/pocketbeagle/post-image.sh`     | edit    | Generate FAT32 image with `mkfs.vfat` + `mcopy` for `config.txt`/`README.txt` |
| `buildroot/external/board/rapidbeagle/pocketbeagle/uEnv.txt`          | edit    | Append `init=/sbin/overlay-init` to kernel cmdline                     |
| `buildroot/external/board/rapidbeagle/pocketbeagle/linux-fragment.config` | verify | Ensure `CONFIG_OVERLAY_FS=y` and `CONFIG_TMPFS=y` are present          |
| `rootfs-overlay/sbin/overlay-init`                                    | new     | PID 1 wrapper that sets up overlayfs and execs `/sbin/init`            |
| `rootfs-overlay/data/.gitkeep`                                        | new     | Creates `/data` mount point in the rootfs                              |
| `rootfs-overlay/etc/init.d/S10-mount-data`                            | new     | Mounts `/dev/mmcblk0p3` RO at `/data`                                  |
| `rootfs-overlay/etc/init.d/S39-usb-gadget`                            | edit    | Replace `ifup usb0` with DHCP-then-static block                        |
| `rootfs-overlay/etc/init.d/S99-app-launcher`                          | edit    | Look in `/data/$app_binary` then `/data/rapidbeagle-app` then `/opt/app/` |
| `rootfs-overlay/etc/network/interfaces`                               | edit    | Remove `usb0` stanza                                                   |
| `data/config.txt` (built into FAT32 image by post-image.sh)           | new     | Commented template                                                     |
| `data/README.txt` (built into FAT32 image)                            | new     | One-paragraph explainer                                                |

---

## Risks & mitigations

| Risk                                                              | Mitigation                                                                                              |
|-------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `overlay-init` fails (mount errors, missing binaries) → unbootable | Script falls back to `exec /sbin/init` on any error. Device boots in legacy RW mode; visible via dmesg. |
| `udhcpc` script `/usr/share/udhcpc/default.script` missing        | Verify presence on existing image during implementation. Add as part of the rootfs overlay if absent.   |
| Data partition corrupted (FAT can corrupt on bad eject)           | `S10-mount-data` logs and continues. App launcher falls back to `/opt/app/`. Device still boots and SSHes. |
| RAM exhaustion via runaway log writes filling tmpfs               | 128 MB cap on tmpfs. With ~490 MB free RAM, even 128 MB tmpfs leaves plenty.                            |
| Write to `/etc` during runtime (e.g. ssh-keygen regenerating keys) | Goes to tmpfs upper. Lost on reboot — same as today since we don't persist host keys. Acceptable.       |
| Boot time regression                                              | Overlay setup adds ~50 ms (kernel ops only). DHCP timeout adds 3s in PC mode — measured, accepted.      |

---

## Acceptance criteria

After implementation, the following must hold on a freshly flashed image:

1. **Read-only rootfs after boot.** `cat /proc/mounts | grep ' / '` shows `overlay` as the filesystem on `/`. The ext4 mount of `/dev/mmcblk0p2` (visible separately under `/proc/mounts` if it appears at all) is `ro`. Writes to `/anywhere` succeed at runtime but disappear after reboot — verifiable by `touch /reboot-test-marker; reboot`, then after boot confirming `/reboot-test-marker` is gone.
2. **Data partition mounted RO at `/data`.** `mount | grep /data` shows `vfat ro`.
3. **`/data/config.txt` readable** by `cat /data/config.txt`.
4. **PC connection: usb0 has static IP.** Connect to Windows PC, observe `192.168.7.2` on `usb0` after ~3-4 seconds.
5. **Android connection: usb0 has DHCP-assigned IP.** Connect to an Android phone with USB tethering enabled, observe `192.168.42.x` (or whatever the phone hands out) on `usb0` within <5s, plus a default route.
6. **App-from-data deploy.** Copy a fresh `rapidbeagle-app` binary onto the FAT32 partition on a PC, reinsert SD into device, power-cycle. The new binary runs without reflashing.
7. **SD removable after boot.** Boot the device, SSH in, `umount /data || true; sync`, physically remove SD card. SSH session stays alive (modulo any reads from the SD that were pending). Reading existing memory-cached files still works; new exec from disk fails (acceptable).
8. **Boot time within budget.** End-to-end power-on → SSH still ≤ 13s on PC connection (≤10s today + ~3s DHCP timeout). On Android (DHCP succeeds), boot is comparable or faster.

---

## Out of scope (future work)

- Persistent SSH host keys (currently regenerated each boot — pre-existed this spec).
- Resizing the data partition on first boot.
- Avahi/mDNS for IP announcement.
- Encrypted config (`config.txt` with credentials is plaintext on FAT32 — acceptable for this device's threat model).
- Dual-boot / failsafe rootfs.
