# RapidBeagle Buildroot Image — Design Spec

**Date:** 2026-04-26
**Project:** RapidBeagle (extends existing repo)
**Goal:** A Buildroot-based custom Linux image for PocketBeagle (AM335x) that boots from power-on to a NativeAOT-compiled .NET application running in **under 10 seconds**, with a target of 5–7 seconds.

---

## Problem Statement

The existing Debian-based optimization script (`optimize-pocketbeagle-boot.sh`) reduces boot time from minutes to ~15–20 seconds, but the systemd dependency tree and stock Debian rootfs prevent reaching a 10-second target. The customer constraint is hard: **a dotnet appliance must reach its userspace app in under 10 seconds.**

A Buildroot-built image starts from "almost nothing" and adds only what's strictly needed. With a stripped kernel, BusyBox init, and no service-manager overhead, the AM335x SoC can reasonably hit a 5–7 second boot to running app.

## Approach

**Buildroot external tree** added to the existing RapidBeagle repository under `buildroot/`, alongside (not replacing) the Debian script. The Buildroot config produces a single `sdcard.img` containing U-Boot, a stripped Linux kernel, and a BusyBox + glibc + openssh + wpa_supplicant rootfs. The user's NativeAOT-compiled dotnet binary is dropped into `/opt/app/` after first boot via SCP and is launched as the final init step.

**Scope:** PocketBeagle (TI AM335x, ARMv7) only. PocketBeagle 2 uses a different SoC (AM6232, aarch64) and is explicitly out of scope — it would require a separate defconfig and toolchain.

**No dotnet runtime is installed on the device.** NativeAOT binaries are statically compiled to native ARM and link against glibc + libstdc++ only.

---

## Repository Layout

```
RapidBeagle/
├── optimize-pocketbeagle-boot.sh        # existing Debian script (untouched)
├── restore-pocketbeagle-boot.sh         # existing
├── .gitattributes                       # existing
├── README.md                            # updated to describe both approaches
├── docs/superpowers/{specs,plans}/      # existing
└── buildroot/                           # NEW
    ├── README.md                        # build & flash instructions
    ├── external/                        # Buildroot BR2_EXTERNAL tree
    │   ├── Config.in                    # external Kconfig hooks (empty initially)
    │   ├── external.desc                # external tree name + version
    │   ├── external.mk                  # external makefile (empty initially)
    │   ├── configs/
    │   │   └── rapidbeagle_pb_defconfig
    │   ├── board/rapidbeagle/pocketbeagle/
    │   │   ├── busybox-inittab          # /etc/inittab content
    │   │   ├── interfaces               # /etc/network/interfaces content
    │   │   ├── post-build.sh            # rootfs-overlay-after hook
    │   │   ├── post-image.sh            # SD image assembly hook
    │   │   ├── genimage.cfg             # SD partition layout
    │   │   ├── linux.config             # stripped kernel config
    │   │   └── rootfs-overlay/
    │   │       ├── etc/init.d/S40-network
    │   │       ├── etc/init.d/S98-pb-heartbeat
    │   │       ├── etc/init.d/S99-app-launcher
    │   │       ├── opt/app/.gitkeep
    │   │       └── root/.ssh/authorized_keys  # populated by post-build
    │   └── package/                     # reserved for any custom packages
    └── scripts/
        ├── build.sh                     # one-command build wrapper
        └── flash-sdcard.sh              # interactive SD flasher with safety checks
```

The `external/` directory is a standard Buildroot convention (`BR2_EXTERNAL`). All RapidBeagle customization lives under it; Buildroot itself is cloned separately and updated independently.

---

## Boot Path

```
[Power on]
    ↓
ROM bootloader (in AM335x silicon)              ~0.5s   (fixed, not tunable)
    ↓ loads MLO/SPL from SD boot partition
SPL (U-Boot stage 1)                            ~0.5s
    ↓ initializes RAM, loads u-boot.img
U-Boot (silent, zero-delay, raw kernel boot)    ~0.5s   (down from ~3s default)
    ↓ loads zImage + DTB, jumps to kernel
Linux kernel (stripped, no modules, "quiet")    ~1.5s
    ↓ mounts root partition directly (no initramfs)
BusyBox init (PID 1) reads /etc/inittab         ~0.5s
    ↓ runs /etc/init.d/Sxx scripts in order
S40 network — usb0 static, wlan0 ready          ~1.0s
S98 pb-heartbeat — fork LED blinker             instant
S99 app-launcher — exec /opt/app/rapidbeagle-app ~0.2s
    ↓
[AOT main() running]                             ~4.7s
    ↓ application initialization (user code)
[App responding]                                 ~5–7s   ✅ <10s ceiling
```

### Key boot-path optimizations

- **No initramfs** — kernel mounts the rootfs directly. Saves ~1s.
- **U-Boot silent mode** (`silent=1`) and **zero boot delay** (`bootdelay=0`) save ~2s vs. defaults.
- **Stripped kernel** with no loadable modules — everything compiled in. No `modprobe` or `udev` time.
- **`quiet` and `loglevel=3`** on kernel cmdline — no printk console I/O.
- **App runs as PID >1** — BusyBox stays as PID 1. App crash does not panic the kernel.
- **`exec` in the launcher script** — replaces the shell, no orphaned shell process.

---

## Kernel Configuration

The kernel is built from `linux.config` derived from BeagleBone `omap2plus_defconfig` with aggressive trimming.

### Kept (must work)

| Category | Items |
|---|---|
| SoC | AM335x / TI OMAP2+ |
| Storage | MMC/SD (`omap_hsmmc`) |
| USB | musb host+gadget, libcomposite, RNDIS, ECM |
| Network | CPSW ethernet (general AM335x), `cfg80211`, `mac80211` |
| WiFi drivers | `rtl8xxxu`, `mt7601u`, `brcmfmac`, `ath9k_htc` (covers common USB dongles) |
| Filesystems | ext4, vfat, tmpfs, configfs, sysfs, procfs |
| Audio | `snd_usb_audio`, `snd_usbmidi_lib`, `snd_rawmidi`, `snd_seq` |
| Crypto | AES, SHA-1/256/512 (for SSH/TLS) |
| Class drivers | LEDs sysfs interface, GPIO sysfs + cdev |
| Misc | RTC (for time), basic OOPS reporting |

### Removed (not needed)

| Category | Items |
|---|---|
| Other SoCs | All non-AM335x ARM platforms |
| Other storage | SATA, NVMe, SCSI, USB mass storage gadget |
| Bluetooth | Entire BT stack (`bluetooth`, `btusb`, `hci_uart`, etc.) |
| Audio | All HDA, SoC audio codecs, McASP, I2S |
| Filesystems | btrfs, xfs, NTFS, ReiserFS, JFFS2 |
| Debugging | ftrace, perf, kgdb, slab debug, lockdep |
| Networking extras | CAN bus, NFC, IPv6 mobile extensions, IP-in-IP, vlans (unless needed) |
| Auditing | audit subsystem |

Expected `zImage` size: **3–4 MB** compressed (down from ~10 MB stock).

---

## Userspace Package Selection

Buildroot defconfig selects:

| Package | Reason |
|---|---|
| `busybox` | init, shell, networking, file utilities — single ~1 MB binary |
| `glibc` | C library NativeAOT links against. Chosen over musl for NuGet compatibility. |
| `libstdc++` | NativeAOT-compiled C# binaries link against this |
| `openssh` | Dev access via SSH key auth |
| `wpa_supplicant` | WiFi association — available, but the dotnet app drives it via control socket |
| `iw` | Wireless utilities (signal info, scanning) |
| `ca-certificates` | TLS root certs for HTTPS calls from the app |
| `tzdata` | Time zones |

**Not included:** apt/dpkg, NetworkManager, systemd, dbus, polkit, locales (English-only), CUPS, Avahi, Bluetooth.

### Expected sizes

| Component | Size |
|---|---|
| MLO + u-boot.img | ~1 MB |
| zImage + DTB | ~5 MB |
| Rootfs (compressed) | ~30–40 MB |
| Free deploy space on rootfs partition | ~200 MB (room for AOT binary, typically 30–80 MB) |
| **Total `sdcard.img`** | **~256 MB** |

---

## Filesystem Layout

```
/                           ext4, read-write (read-only is a future improvement)
├── bin, sbin, lib           BusyBox + glibc + libs
├── etc/
│   ├── inittab              BusyBox init config
│   ├── init.d/
│   │   ├── rcS              BusyBox standard rcS (runs all S* scripts)
│   │   ├── S40-network
│   │   ├── S98-pb-heartbeat
│   │   └── S99-app-launcher
│   ├── network/interfaces
│   ├── ssh/                 sshd config + host keys
│   └── wpa_supplicant.conf  empty by default; app populates at runtime
├── opt/app/                 DEPLOY TARGET — AOT binary lives here
│   └── rapidbeagle-app      (created by user via scp after first boot)
├── boot/                    kernel + DTB (also present in boot partition)
├── home/                    optional dev home dirs
├── root/.ssh/authorized_keys   pre-populated at build time from user's pubkey
└── var, run, tmp            tmpfs-mounted (volatile)
```

---

## Networking

| Interface | Configuration | Auto-up at boot? |
|---|---|---|
| `usb0` (USB gadget) | Static `192.168.7.2/24` | **Yes** — for dev access |
| `eth0` (none on PB) | DHCP (if interface present) | Yes if present, skipped otherwise |
| `wlan0` (USB WiFi dongle) | Driver loaded, `wpa_supplicant` available | **No** — dotnet app drives it via control socket |

The host PC is expected at `192.168.7.1` on USB gadget. `wpa_supplicant` runs in "no auto-connect" mode — the dotnet app initiates connections by writing to `/var/run/wpa_supplicant/wlan0` control socket.

---

## SSH Access (Development)

`openssh` listens on port 22, key-based auth only:

- Build-time: user's `~/.ssh/id_ed25519.pub` is copied into the rootfs at `/root/.ssh/authorized_keys` via `post-build.sh`.
- Password authentication is disabled in `sshd_config`.
- Host keys are generated on first boot if not present (small ~1s delay first boot only — acceptable trade-off vs shipping fixed keys).

A future build flag `RAPIDBEAGLE_SSH=off` will remove openssh entirely for production images. Not in v1.

---

## App Launcher

`/etc/init.d/S99-app-launcher`:

```sh
#!/bin/sh
# Launch the RapidBeagle dotnet AOT application
APP=/opt/app/rapidbeagle-app

case "$1" in
    start)
        if [ ! -x "$APP" ]; then
            echo "S99-app-launcher: $APP not found or not executable — skipping"
            exit 0
        fi
        # Mark boot complete so the heartbeat transitions to "app starting"
        touch /run/boot-complete
        # Launch the app in the background, capture PID
        "$APP" >> /var/log/app.log 2>&1 &
        echo $! > /run/app.pid
        ;;
    stop)
        if [ -f /run/app.pid ]; then
            kill "$(cat /run/app.pid)" 2>/dev/null
            rm -f /run/app.pid
        fi
        ;;
esac
```

**Design choices:**
- App runs in background, NOT `exec`'d (the original design). This allows the launcher to capture PID, and means a crashed app does not block init script processing.
- PID file at `/run/app.pid` lets the heartbeat script and any future watchdog know whether the app is alive.
- Logs to `/var/log/app.log` (tmpfs, lost on reboot — acceptable for a v1 appliance; persistence is a future improvement).
- Missing/non-executable binary → silent exit 0. Boot still completes, device is reachable via SSH for deploying the binary.

---

## LED Heartbeat

`/etc/init.d/S98-pb-heartbeat` — same three-state behavior as the Debian version, simpler implementation:

| State trigger | LED pattern |
|---|---|
| `/run/boot-complete` does NOT exist | Fast blink (5 Hz) — "still booting" |
| `/run/boot-complete` exists, `/run/app.pid` missing or process dead | Slow blink (0.5 Hz) — "boot complete, app not running" |
| `/run/app.pid` points to a live process | Steady on — "app running" |

The heartbeat script forks into the background as PID >1 (not from init directly), reclaims USR0 from the kernel `heartbeat` trigger by writing `none` to `/sys/class/leds/beaglebone:green:usr0/trigger`, then loops checking the boot-complete flag and PID.

---

## Build & Flash Workflow

### One-time WSL2 setup

```bash
sudo apt update
sudo apt install -y build-essential git cpio unzip rsync bc python3 \
                    file wget libncurses-dev gawk
```

Build runs in WSL2 native filesystem (`~/build/`), not under `/mnt/c/`.

### One-time clones

```bash
cd ~/
git clone https://git.busybox.net/buildroot
git clone https://github.com/kurtnelle/RapidBeagle.git
```

### Build (one command)

```bash
cd ~/buildroot
make BR2_EXTERNAL=~/RapidBeagle/buildroot/external rapidbeagle_pb_defconfig
make
```

First run: 30–60 minutes. Incremental rebuilds: 2–10 minutes.

### Output

```
~/buildroot/output/images/sdcard.img       ← flash this
~/buildroot/output/images/zImage
~/buildroot/output/images/am335x-pocketbeagle.dtb
~/buildroot/output/images/u-boot.img
~/buildroot/output/images/MLO
~/buildroot/output/images/rootfs.tar       ← rootfs alone, useful for NFS/quick iter
```

### Flash to SD card

```bash
sudo ~/RapidBeagle/buildroot/scripts/flash-sdcard.sh /dev/sdb
```

The wrapper:
- Refuses to write to `/dev/sda` (likely your boot disk)
- Asks for explicit confirmation showing model + size of target
- Verifies write integrity
- Ejects safely

### Iteration loop

For app code changes (most common):
```bash
dotnet publish -c Release -r linux-arm --self-contained -p:PublishAot=true -o publish/
scp publish/rapidbeagle-app root@192.168.7.2:/opt/app/
ssh root@192.168.7.2 reboot
```

For image changes (less common):
1. Edit files in `~/RapidBeagle/buildroot/external/...`
2. `make` (incremental)
3. Reflash SD card (or scp just the new `zImage`/`rootfs` to `/boot/`)

---

## Success Criteria

The image is "done" when all these are true on a flashed SD card with a deployed AOT binary:

| Criterion | Target |
|---|---|
| Power-on to USR0 LED blinking | < 2 seconds |
| Power-on to SSH reachable on `usb0` | < 8 seconds |
| Power-on to AOT app `main()` running | < 8 seconds |
| Power-on to app fully responding | < 10 seconds (the hard ceiling) |
| Image rebuilds reproducibly from the same git commit | Yes |
| Build is one command after one-time setup | Yes |
| USB MIDI controller enumerates as `/dev/snd/midiC*` when plugged into host port | Yes |
| WiFi USB dongle works when dotnet app initiates connection via wpa_supplicant control | Yes |
| USB gadget networking works on first boot at `192.168.7.2` | Yes |
| Re-flashing returns the device to a known-good state | < 5 minutes wall-clock |

---

## Out of Scope (v1)

These are explicitly NOT in this design — captured here so they don't get added by accident:

- **PocketBeagle 2 support** (different SoC, separate effort)
- **Read-only rootfs** (future hardening; v1 is read-write ext4)
- **A/B partition updates** / OTA
- **Persistent log storage** (`/var/log` is tmpfs in v1)
- **Production SSH-removed image** flag
- **Custom dotnet runtime packaging** (NativeAOT only — no JIT runtime)
- **Bluetooth, CAN bus, I2C/SPI userspace drivers** (kernel supports them but no userspace tooling shipped)
- **Time synchronization** (NTP client) — punt to dotnet app or future improvement

---

## References

- Buildroot manual: https://buildroot.org/downloads/manual/manual.html
- Buildroot BR2_EXTERNAL convention: https://buildroot.org/downloads/manual/manual.html#outside-br-custom
- AM335x reference: TI AM335x Sitara Processors datasheet
- PocketBeagle hardware: https://beagleboard.org/pocket
- NativeAOT for ARM: https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/
- Existing Debian optimization spec: `docs/superpowers/specs/2026-04-25-pocketbeagle-boot-design.md`
