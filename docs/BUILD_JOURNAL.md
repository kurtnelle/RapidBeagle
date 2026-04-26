# RapidBeagle Buildroot Build Journal

**Purpose:** Everything we learned bringing up the original PocketBeagle. When you do this again for PocketBeagle 2 (or any other AM335x/AM62x board), this is the checklist.

---

## Final state on PocketBeagle (TI AM335x, ARMv7 single-core Cortex-A8 @ 1 GHz)

| Metric | Result |
|---|---|
| Boot to USR0 LED | < 2s (visible immediately on power-on) |
| Kernel start → userspace ready (`/run/boot-time.log`) | **9.31s** (varies 6.9–9.5s due to host USB enumeration) |
| Kernel start → SSH reachable | similar — sshd starts before our boot-time log |
| Power-on → SSH reachable end-to-end | ~10–12s (PowerShell timer measurement, includes ROM + U-Boot) |
| Image size on SD | 268 MB (16 MB boot FAT + 240 MB ext4 rootfs, ~32 MB used) |
| RAM used at idle | ~18 MB of 490 MB |

The 10s ceiling we promised is met for kernel + userspace. ROM + U-Boot adds ~2s, so total is often slightly over 10s. The single biggest variability is **the USB host's enumeration delay** — `S39-usb-gadget` blocks until the UDC binds, which Windows takes 2–7s to complete depending on USB hub/port state. There's nothing we can do about the host side; this is the practical floor.

---

## Build environment

- **Host:** Windows 11 with WSL2 (Ubuntu 20.04 LTS) running on Hyper-V
- **WSL2 specs:** 16 cores allocated, 31 GB RAM, ~250 GB disk available — full kernel rebuild ~5 min, rootfs-only rebuild ~30s
- **Buildroot version:** 2024.02.x LTS (cloned from `https://gitlab.com/buildroot.org/buildroot.git`, branch `2024.02.x`, tagged `2024.02.13`)
- **Linux kernel:** 6.6.30 (LTS)
- **U-Boot:** **NOT mainline**. We use BeagleBoard.org's fork:
  - URL: `https://git.beagleboard.org/beagleboard/u-boot.git`
  - Branch: `v2022.04-bbb.io-am335x-am57xx`
  - Reason: see "Pitfall 6" below.

---

## Pitfall log (every issue we hit, in order)

This is the complete list. When something breaks during PB2 bringup, check here first.

### 1. `log()` returned non-zero, `set -e` killed the Debian script after the guard check
**Symptom:** Original Debian optimization script printed only `Guard checks passed` then exited.
**Cause:** `log() { …; [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"; }` — when `LOG_FILE` was empty, the `&&` short-circuited and made the function's last command return 1; `set -e` picked that up and exited.
**Fix:** Add explicit `return 0` to `log()`.
**Lesson:** With `set -e`, never let a function's last statement be a `&&` test that may legitimately fail.

### 2. `uEnv.txt` not detected by the Debian script
**Symptom:** Phase 4 (kernel cmdline patcher) skipped.
**Cause:** BeagleBoard.org's Trixie image stores cmdline in `/boot/uEnv.txt`, not `/boot/firmware/extlinux/extlinux.conf` or `/boot/cmdline.txt`.
**Fix:** Added uEnv.txt detection with format-aware sed pattern.
**Lesson:** AM335x BeagleBoard uses U-Boot env file; AM62x might use yet another path.

### 3. State capture had `\nnot-found` glued to actual state
**Symptom:** Service skip message read `Already not enabled (disabled\nnot-found): foo.service`.
**Cause:** `systemctl is-enabled disabled-svc` returns exit 1 with output `disabled` — combining with `|| echo "not-found"` appended both.
**Fix:** Use `systemctl is-enabled "${svc}" 2>/dev/null | head -n1` and treat empty as "unknown".

### 4. Kernel build failed: `am335x-pocketbeagle.dtb` no rule
**Symptom:** Kernel compile error at DTS phase.
**Cause:** Linux 6.5+ moved ARM device trees into vendor subdirectories (`arch/arm/boot/dts/ti/omap/...`).
**Fix:** `BR2_LINUX_KERNEL_INTREE_DTS_NAME="ti/omap/am335x-pocketbeagle"` (with the path).
**For PB2:** Will be `BR2_LINUX_KERNEL_INTREE_DTS_NAME="ti/k3-am625-pocketbeagle2"` or similar — verify against the kernel source.

### 5. `mtools` / `mcopy` missing on host
**Symptom:** `genimage` failed building `boot.vfat` with `/bin/sh: 1: mcopy: not found`.
**Cause:** Buildroot needs the host system to have `mtools` and `dosfstools` installed when the image has a FAT partition.
**Fix:** `apt install mtools dosfstools` on the WSL2 host.
**Add to:** Build prerequisites checklist; could also add a `command -v mcopy` check to `build.sh`.

### 6. **U-Boot 2024.01 timer regression on AM335x — boot loops**
**Symptom:** Serial console showed:
```
Could not initialize timer (err -19)
esetting ...
```
…and the device looped through SPL/U-Boot forever, never loading the kernel.
**Cause:** Mainline U-Boot's `am335x_evm_defconfig` had a regression in 2023.10 / 2024.01 affecting AM335x driver-model timer init.
**Fix:** Switch the U-Boot source to BeagleBoard.org's fork:
```
BR2_TARGET_UBOOT_CUSTOM_GIT=y
BR2_TARGET_UBOOT_CUSTOM_REPO_URL="https://git.beagleboard.org/beagleboard/u-boot.git"
BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION="v2022.04-bbb.io-am335x-am57xx"
```
**For PB2:** BeagleBoard.org has dedicated PB2 branches like `v2025.04-pocketbeagle2` — use the latest stable one for AM62.

### 7. `ifup: duplicate option "allow-hotplug"`
**Symptom:** `Starting network: ifup: duplicate option "allow-hotplug" — FAIL`
**Cause:** `/etc/network/interfaces` had both `auto usb0` and `allow-hotplug usb0` for the same interface — `ifup` rejects.
**Fix:** Use one or the other. We use `allow-hotplug` because the gadget interface only appears after `S39-usb-gadget` runs.

### 8. **Most of the USB stack was built as kernel modules** (`=m`) — never loaded
**Symptom:** `/sys/class/udc/` empty; no `musb` lines in dmesg.
**Cause:** `omap2plus_defconfig` defaults `CONFIG_USB=m`, `CONFIG_AM335X_PHY_USB=m`, `CONFIG_TI_CPPI41=m`, `CONFIG_NOP_USB_XCEIV=m`. Our minimal init has no `modprobe`/udev that auto-loads modules at boot.
**Fix:** Force everything we need to `=y` in `linux-fragment.config`. Full list (PB-specific names, may differ on PB2):
```
CONFIG_USB=y
CONFIG_USB_SUPPORT=y
CONFIG_USB_COMMON=y
CONFIG_USB_ANNOUNCE_NEW_DEVICES=y
CONFIG_USB_MUSB_HDRC=y
CONFIG_USB_MUSB_DSPS=y
CONFIG_USB_MUSB_DUAL_ROLE=y
CONFIG_AM335X_PHY_USB=y
CONFIG_AM335X_CONTROL_USB=y
CONFIG_NOP_USB_XCEIV=y
CONFIG_TI_CPPI41=y
CONFIG_USB_TI_CPPI41_DMA=y
CONFIG_USB_GADGET_MUSB_HDRC=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_GADGET=y
CONFIG_USB_LIBCOMPOSITE=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_F_ACM=y
CONFIG_USB_F_ECM=y
CONFIG_USB_F_RNDIS=y
CONFIG_USB_F_NCM=y
CONFIG_U_SERIAL=y
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_USB_CONFIGFS_RNDIS=y
CONFIG_USB_CONFIGFS_ECM=y
CONFIG_USB_CONFIGFS_NCM=y
```
**For PB2:** AM62 uses **DWC3** USB controller, not MUSB. Replace `CONFIG_USB_MUSB_*` and `CONFIG_AM335X_*` with `CONFIG_USB_DWC3=y`, `CONFIG_USB_DWC3_AM62=y`, `CONFIG_PHY_AM62_USB2=y`, etc. Likewise `CONFIG_TI_CPPI41` is AM335x-specific — PB2 will need the AM62 DMA driver which is different.

### 9. MUSB `CONFIG_USB_MUSB_DUAL_ROLE` silently dropped
**Symptom:** `cat /sys/class/udc/musb-hdrc.0/mode` returned `b_peripheral` (correct OTG state), but `/sys/class/udc/` was empty.
**Cause:** `USB_MUSB_HOST` / `USB_MUSB_GADGET` / `USB_MUSB_DUAL_ROLE` are a Kconfig **`choice`** (mutually exclusive). Setting all three `=y` made Kconfig pick HOST silently and discard DUAL_ROLE — kernel had no peripheral driver.
**Fix:** Explicitly disable HOST and GADGET in the fragment so DUAL_ROLE wins:
```
# CONFIG_USB_MUSB_HOST is not set
# CONFIG_USB_MUSB_GADGET is not set
CONFIG_USB_MUSB_DUAL_ROLE=y
```
**For PB2:** DWC3 has its own dual-role plumbing (`CONFIG_USB_DWC3_DUAL_ROLE=y`) — same trap probably applies.

### 10. `usb0` interface stayed DOWN after gadget bound
**Symptom:** `/sys/class/udc/musb-hdrc.0` populated, gadget configured, but `ip link` showed `usb0: <BROADCAST,MULTICAST>` (no `UP`, no IP).
**Cause:** The interface only appears AFTER `S39-usb-gadget` writes to `/sys/.../UDC`. The kernel does NOT emit a hotplug uevent for configfs-created interfaces, so `allow-hotplug usb0` in `/etc/network/interfaces` never fires.
**Fix:** Run `ifup usb0` explicitly at the end of `S39-usb-gadget` after UDC bind.

### 11. **Windows enumerated the RNDIS gadget as a USB serial port**
**Symptom:** Device Manager showed `USB Serial Device (COM7)` instead of a network adapter. No NIC under "Network adapters". RNDIS sub-device showed Error.
**Cause:** Linux 6.x removed `CONFIG_USB_RNDIS_WCEIS`. Without it, `f_rndis` hardcodes its control-interface descriptor as `CDC class (0x02) / ACM subclass (0x02) / Vendor protocol (0xFF)`. Windows reads CDC + ACM and creates a COM port.
**Fix:** Don't use RNDIS. Use **CDC NCM** instead — Windows 8.1+, Linux 3.x+, macOS 10.10+ all bind it natively as a network adapter with no OS descriptor magic.
**Implementation:** Two configurations:
- Config 1: **NCM** (Windows + modern hosts, including BMPCC4K)
- Config 2: **ECM** (legacy Linux fallback)

The host enumerates both, picks the one it has a driver for. No conflict, no driver hassle, both worlds covered.

**Worth noting:** `f_rndis` may come back to `=y` on `WCEIS` defaults in some future kernel. If you want native Windows + classic Linux without NCM, keep an eye on mainline — but NCM is the right answer right now.

### 12. Random MAC each boot → Windows creates a fresh adapter every time, static IP orphaned
**Symptom:** First boot: Windows assigns "Ethernet 7", you set 192.168.7.1. Reboot the PocketBeagle: Windows now sees "Ethernet 8" (no IP), and "Ethernet 7" is disconnected.
**Cause:** The kernel auto-generates a random MAC for each gadget function on every boot.
**Fix:** Pin stable MACs in `S39-usb-gadget` after creating the function:
```
echo "fa:da:da:da:7e:01" > functions/ncm.usb0/dev_addr
echo "fa:da:da:da:7e:02" > functions/ncm.usb0/host_addr
echo "fa:da:da:da:7e:11" > functions/ecm.usb0/dev_addr
echo "fa:da:da:da:7e:12" > functions/ecm.usb0/host_addr
```
Locally-administered (bit 1 of first octet = 1) so we don't collide with real OUIs.

### 13. SSH key not baked into image
**Symptom:** `ssh root@192.168.7.2` after every reflash returned `Permission denied (publickey,keyboard-interactive)` — every fresh image had no `authorized_keys`.
**Cause:** `post-build.sh` looks for `$RAPIDBEAGLE_SSH_PUBKEY` (default `$HOME/.ssh/id_ed25519.pub`) — Buildroot runs as root in WSL2, so it expects `/root/.ssh/id_ed25519.pub`. We never put one there until late in the process.
**Fix (one-time):** On the WSL2 host, `cp /mnt/c/Users/<you>/.ssh/id_ed25519.pub /root/.ssh/id_ed25519.pub`. Future builds bake it in automatically.

### 14. Interactive SSH: `PTY allocation request failed on channel 0`
**Symptom:** Non-interactive SSH (`ssh host "command"`) worked, but `ssh host` for a shell failed with PTY error.
**Cause:** `/dev/pts` directory and `devpts` filesystem weren't mounted at boot. The kernel auto-creates `/dev/ptmx` via devtmpfs but the pts mount needs userspace.
**Fix:** Add to inittab:
```
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
```

---

## Image components and contents

| Component | Source | Notes |
|---|---|---|
| `MLO` (SPL) | BB.org U-Boot fork | Built by Buildroot's U-Boot package |
| `u-boot.img` | BB.org U-Boot fork | Same |
| `uEnv.txt` | Our `board/.../uEnv.txt`, copied by `post-image.sh` | Sets `silent=1`, `bootdelay=0`, `quiet loglevel=3` |
| `zImage` | Linux 6.6.30 + our fragment | ~7.7 MB compressed |
| `am335x-pocketbeagle.dtb` | Mainline kernel DTS at `ti/omap/` | Standard PocketBeagle device tree |
| `rootfs.ext4` | Buildroot rootfs | 240 MB allocated, ~32 MB used; mounted RW currently |
| Boot partition | FAT16, 16 MB | First partition on SD, holds MLO + u-boot.img + zImage + DTB + uEnv.txt |

---

## Userspace stack on the device

- **init:** BusyBox init, reading `/etc/inittab`
- **C library:** glibc (chosen over musl for NuGet/dotnet AOT compatibility)
- **C++ stdlib:** libstdc++ (NativeAOT C# binaries link against this)
- **Shell:** BusyBox `ash`, no bash
- **SSH:** OpenSSH (key auth only — `post-build.sh` disables password auth)
- **WiFi:** wpa_supplicant present but not auto-started; dotnet app drives it via control socket
- **CA certs:** ca-certificates (for dotnet HTTPS calls)
- **Time zones:** tzdata (UTC + a couple zones)
- **Network up scripting:** ifupdown-scripts + `/etc/network/interfaces`

---

## Init script execution order

```
S01-syslogd       (BusyBox standard)
S02-klogd         (BusyBox standard)
S20urandom        (random seed)
S39-usb-gadget    (OUR — creates NCM+ECM gadget, binds UDC, runs ifup usb0)
S40-network       (ifupdown — for any other interfaces; usb0 already up by here)
S50sshd           (OpenSSH server)
S98-pb-heartbeat  (OUR — USR0 LED state machine)
S99-app-launcher  (OUR — records boot-time, launches /opt/app/rapidbeagle-app if present)
```

---

## Files in the repo (per-board pieces)

```
buildroot/
├── README.md                                    Build instructions
├── FIRST_BUILD_CHECKLIST.md                     One-time WSL2 setup
├── external/
│   ├── external.desc                            Tree name
│   ├── external.mk                              Custom packages (none yet)
│   ├── Config.in                                Custom Kconfigs (none yet)
│   ├── configs/rapidbeagle_pb_defconfig         <<< CHANGE THIS FOR PB2
│   └── board/rapidbeagle/pocketbeagle/          <<< COPY+RENAME FOR PB2
│       ├── linux-fragment.config                Kernel CONFIG_ overrides
│       ├── uEnv.txt                             U-Boot env (PB2: extlinux probably)
│       ├── genimage.cfg                         SD partition layout
│       ├── post-build.sh                        SSH key install + sshd hardening
│       ├── post-image.sh                        Calls genimage to assemble sdcard.img
│       └── rootfs-overlay/etc/
│           ├── inittab                          BusyBox init (mounts, getty)
│           ├── network/interfaces               usb0 static, eth0 DHCP
│           ├── wpa_supplicant.conf              WiFi config (empty, app fills)
│           └── init.d/
│               ├── S39-usb-gadget               Gadget setup with stable MACs
│               ├── S98-pb-heartbeat             USR0 LED state machine
│               └── S99-app-launcher             Boot-time stamp + dotnet launch
└── scripts/
    ├── build.sh                                 One-command build wrapper
    └── flash-sdcard.sh                          SD flasher with safety checks
```

---

## Doing it again for PocketBeagle 2

**PocketBeagle 2 hardware vs original PocketBeagle:**

| | PocketBeagle | PocketBeagle 2 |
|---|---|---|
| SoC | TI AM335x | TI AM6232 (often called AM62) |
| Architecture | ARMv7 (32-bit) | **AArch64 (64-bit)** |
| CPU | 1× Cortex-A8 @ 1 GHz | **2× Cortex-A53 @ 1.4 GHz** + 2× Cortex-R5F (real-time, not Linux) |
| RAM | 512 MB DDR3 | 1 GB DDR4 |
| USB controller | MUSB | **DWC3** |
| GPU | PowerVR SGX530 | None or different |
| Boot path | SPL → U-Boot → kernel | Slightly different (TI K3 uses tiboot3.bin → tispl.bin → u-boot.img) |

The user calls it "quad core" because there are 2× A53 + 2× R5F. **Linux only sees the 2× A53**; the R5Fs are MCUs running TI-RTOS or bare-metal (great for your motor control / real-time MIDI tasks but not part of "boot speed"). Quad-A53 variants exist (AM6442) but **PB2 is dual-A53**.

### Expected speedup for PB2

| Phase | PB (AM335x) | PB2 (AM62) estimate | Reasoning |
|---|---|---|---|
| ROM + SPL + U-Boot | 2–3s | ~1.5–2s | TI K3 ROM loads tiboot3 fast; U-Boot also faster on A53 |
| Kernel decompress + boot | 1.5s | **~0.5–0.8s** | A53 OoO + 2x cores SMP boot ~2-3x faster |
| Init scripts (USB gadget bind, sshd, etc.) | 5–6s (mostly waiting on host enumeration) | **~3–4s** | USB enum still depends on host; less kernel work between scripts |
| **Kernel-to-userspace total** | **6.9–9.5s** | **~3–5s estimated** | A53 cores parallelize `S*` script execution if init is parallel |
| End-to-end power-on → SSH | ~10–12s | **~5–7s estimated** | |

**Realistic prediction: 5–7 seconds power-on to dotnet AOT app responding on PB2.** Depending on init script ordering you could potentially go even lower with an RT-friendly setup (initramfs-only, `init=` directly to dotnet, etc.) but that's optimization beyond what we need.

### What changes for PB2

You'll be redoing approximately one full session of work, but with this journal as a checklist most pitfalls are already documented. Concrete changes needed:

1. **Buildroot defconfig** — copy `rapidbeagle_pb_defconfig` to `rapidbeagle_pb2_defconfig`, then change:
   ```
   # Architecture
   - BR2_arm=y
   - BR2_cortex_a8=y
   + BR2_aarch64=y
   + BR2_cortex_a53=y

   # Kernel DTS
   - BR2_LINUX_KERNEL_INTREE_DTS_NAME="ti/omap/am335x-pocketbeagle"
   + BR2_LINUX_KERNEL_INTREE_DTS_NAME="ti/k3-am625-pocketbeagle2"   (verify against kernel source)

   # Kernel format — AArch64 uses Image, not zImage
   - BR2_LINUX_KERNEL_ZIMAGE=y
   + BR2_LINUX_KERNEL_IMAGE=y

   # U-Boot — different branch in the BB.org fork
   - BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION="v2022.04-bbb.io-am335x-am57xx"
   + BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION="v2025.04-pocketbeagle2"   (or latest tag)

   # U-Boot defconfig — completely different name on K3
   - BR2_TARGET_UBOOT_BOARD_DEFCONFIG="am335x_evm"
   + BR2_TARGET_UBOOT_BOARD_DEFCONFIG="am62x_evm_a53"   (verify in U-Boot source)

   # K3 uses tispl.bin instead of MLO
   - BR2_TARGET_UBOOT_SPL_NAME="MLO"
   + BR2_TARGET_UBOOT_SPL_NAME="tispl.bin"
   ```

2. **`linux-fragment.config`** — replace AM335x USB drivers with DWC3:
   ```
   - CONFIG_USB_MUSB_HDRC=y
   - CONFIG_USB_MUSB_DSPS=y
   - CONFIG_USB_MUSB_DUAL_ROLE=y
   - CONFIG_AM335X_PHY_USB=y
   - CONFIG_AM335X_CONTROL_USB=y
   - CONFIG_TI_CPPI41=y
   - CONFIG_USB_TI_CPPI41_DMA=y
   - CONFIG_USB_GADGET_MUSB_HDRC=y
   + CONFIG_USB_DWC3=y
   + CONFIG_USB_DWC3_AM62=y          # AM62-specific glue (verify name)
   + CONFIG_PHY_TI_AM625_SERDES=y    # PHY (verify name)
   ```
   The dual-role gotcha (Pitfall 9) likely applies to DWC3 too — verify.

3. **`uEnv.txt`** — TI K3 uses extlinux/distro boot. PocketBeagle 2 typically boots via `boot.scr` or `extlinux/extlinux.conf`, NOT `uEnv.txt`. Replace with the appropriate format.

4. **`genimage.cfg`** — partition layout differs slightly (TI K3 boot expects tiboot3.bin in a specific offset). Consult the BeagleBoard.org PB2 SD layout reference.

5. **`post-image.sh`** — likely no change.

6. **`S39-usb-gadget`** — UDC name will change. On AM335x it's `musb-hdrc.0`; on AM62 it's typically `xhci-hcd.NNNN.auto` or similar. The script already does `UDC=$(ls $UDC_PATH | head -n1)` so it'll auto-detect, but the `dev_addr`/`host_addr` writes are function-level so they keep working.

7. **PRU/R5F support (if you want to use them)** — TI's `remoteproc` framework. Out of scope for first boot but easy to add via Buildroot's `ti-rpmsg-char` package.

8. **dotnet AOT triple changes** — `linux-arm` becomes `linux-arm64`. Your AOT'd binaries get bigger (~30%) but execute faster.

### Pre-flight checklist for PB2

- [ ] Copy `buildroot/external/board/rapidbeagle/pocketbeagle/` → `pocketbeagle2/`
- [ ] Copy and rename `rapidbeagle_pb_defconfig` → `rapidbeagle_pb2_defconfig`
- [ ] Apply the 8 changes above to the defconfig
- [ ] Verify the kernel DTS path actually exists in Linux 6.6.x source: `find arch/arm64/boot/dts/ti -name 'k3-am6*pocket*'`
- [ ] Verify the BB.org U-Boot branch exists and is recent: check `https://git.beagleboard.org/beagleboard/u-boot/-/branches`
- [ ] Verify the U-Boot defconfig name in their tree: `ls configs/ | grep am62`
- [ ] Read the BeagleBoard.org PB2 official guide for any board-specific quirks
- [ ] Build, flash, watch serial console at the PB2's UART (note: voltage levels and pin location may differ from PB1)
- [ ] Apply the journal as you go — most pitfalls likely repeat

The goal: have a working `dist/sdcard.img` for PB2 within ~3-4 hours from this checklist, instead of the full session this took for PB1.

---

## Actively investing for the future

**Things still on the TODO list that PB2 should also have:**

- `overlayfs root` for read-only SD operation (zero SD wear, removable card after boot)
- Bake `/etc/machine-id` deterministically so SSH host keys persist across reflash
- Bake **the** SSH pubkey at build time (already wired up — just put it in `/root/.ssh/id_ed25519.pub` on WSL2 side once)
- Resize `rootfs.ext4` to actual content size + slack instead of 240 MB allocated for ~32 MB used
- Dependency check at top of `build.sh` (mtools, dosfstools, gawk, etc.)

---

## Useful one-liners

**Boot timing (from any session):**
```sh
ssh root@192.168.7.2 "cat /run/boot-time.log"
```

**End-to-end power-on → SSH (PowerShell):**
```powershell
$s = Get-Date
do { ssh -o ConnectTimeout=1 -o BatchMode=yes root@192.168.7.2 "true" 2>$null } until ($LASTEXITCODE -eq 0)
"{0:N2}s" -f ((Get-Date)-$s).TotalSeconds
```

**Watch the build live (WSL2):**
```sh
tail -f /tmp/buildroot-build*.log
```

**Drive the device via serial when usb0 is broken (Windows):**
```sh
python C:/Users/shawn/AppData/Local/Temp/pb-serial.py "<command>"
```

**Power off cleanly before pulling SD:**
```sh
ssh root@192.168.7.2 "poweroff"
# wait for "reboot: Power down." on serial console
```

---

## Useful references

- Buildroot manual: https://buildroot.org/downloads/manual/manual.html
- BeagleBoard.org U-Boot fork: https://git.beagleboard.org/beagleboard/u-boot
- TI AM62 SDK / PB2 official: https://www.beagleboard.org/boards/pocketbeagle-2
- USB gadget configfs docs: `Documentation/usb/gadget_configfs.rst` in kernel tree
- Linux DTS path migration (6.5+): https://lore.kernel.org/all/...

---

*Last updated 2026-04-26 after the original PocketBeagle bring-up session.*
