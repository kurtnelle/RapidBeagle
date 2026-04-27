# RapidBeagle — handoff for new chat session

> Use this doc to bootstrap a new Claude session. Everything below is current as of the moment of the handoff.

---

## Project context

- **Repo:** `I:\Source\repos\RapidBeagle` (Windows host). GitHub remote: `https://github.com/kurtnelle/RapidBeagle`.
- **Buildroot clone in WSL2:** `~/RapidBeagle` (separate from Windows checkout). Buildroot itself at `~/buildroot` (branch `2024.02.x`, tag `2024.02.13`). Both clones live on WSL2's native filesystem (NOT under `/mnt/c/...`).
- **Build host SSH:** `ssh -p 2222 root@localhost` from Git Bash on Windows. Key auth set up via Claude's `~/.ssh/id_ed25519`.
- **Target:** PocketBeagle (TI AM335x, ARMv7 single-core Cortex-A8 @ 1 GHz, 512 MB RAM). Plans for PocketBeagle 2 (AM62 dual-A53 aarch64) documented in `docs/BUILD_JOURNAL.md` § "Doing it again for PocketBeagle 2".
- **Device SSH:** `ssh root@192.168.7.2` from Git Bash. USB gadget NCM. Stable host MAC `FA:DA:DA:DA:7E:02` so Windows side keeps its `192.168.7.1/24` static IP across reboots.
- **Goal:** <10s boot to NativeAOT .NET app.

---

## What's working ✅

| Milestone | Detail |
|---|---|
| Boot time | **8.40s kernel-to-userspace** (`/run/boot-time.log`); ~10-12s end-to-end power-on → SSH |
| Kernel | Linux 6.6.30, no modules built-in for kernel; OOT modules load via `/etc/init.d/S30-load-modules` |
| Bootloader | BeagleBoard.org U-Boot fork (`v2022.04-bbb.io-am335x-am57xx`) — mainline 2024.01 has timer regression on AM335x |
| USB gadget | NCM (Windows native) + ECM (Linux/macOS/BMPCC4K). Dual-config. Stable MACs. `usb0=192.168.7.2/24` brought up automatically by `S39-usb-gadget` |
| SSH | `openssh`, key-baked-in via post-build.sh, password auth disabled, devpts mounted for interactive shells |
| .NET 10 | ASP.NET Core runtime 10.0.7 at `/opt/dotnet/`, `/usr/bin/dotnet` symlinked, deps (openssl, libcurl, libicu, libunwind, krb5) installed |
| LED heartbeat | `pb-heartbeat.service` blinks USR0 — fast during boot, slow after S99-app-launcher writes `/run/boot-complete`, steady when app PID alive |
| Boot timing log | Persistent `/run/boot-time.log` written by S99-app-launcher |
| Image size | 268 MB without dotnet, 529 MB with dotnet (rootfs allocated 512 MB) |

`dist/sdcard.img` is the latest produced image. Latest known-good MD5 (without WiFi): `a669fb28...` (aircrack-ng v5.13.6 + cfg80211 6.6 patches; loaded but didn't get the chip live).

---

## Current pending issue: WiFi driver for Edimax EW-7811UTC AC600

Hardware: Edimax AC600 USB dongle, USB ID `7392:a812`, **RTL8811AU chipset**.

### What we tried, in order

1. **aircrack-ng/rtl8812au v5.13.6** — full chipset coverage but wouldn't compile against Linux 6.6 (cfg80211 + REGULATORY_IGNORE_STALE_KICKOFF). With our 3 patches (cfg80211 punct_bitmap, regd flag → 0, Edimax USB ID), it built and got the dongle to load 88XXau.ko, create wlan0, upload firmware to chip, chip checksummed FW OK… but chip MCU never set `WINTINI_RDY` → `_FWFreeToGo8812: Polling FW ready Fail!`. Rejected.
2. **morrownr/8812au-20210820** — compiled but lacks RTL8821A source files (stripped from this fork). Won't work for AC600. Rejected.
3. **morrownr/8821au-20210708** (CURRENT, in-flight) — dedicated 8811AU/8821AU repo, kernel 6.6 compatible, distinct HAL init. First build attempts hit:
   - `obj-m` empty until we passed `CONFIG_RTL8821AU=m` (note: 8821**AU**, not 8812AU like the other forks)
   - `_FW_UNDER_SURVEY` symbol-rename inconsistency (same as morrownr/8812au) — sed-fixed via POST_EXTRACT hook

### Build status at handoff: ✅ COMPLETE

The morrownr/8821au-20210708 build succeeded with both fixes (`CONFIG_RTL8821AU=m` + `_FW_UNDER_SURVEY` sed). Module produced: `/lib/modules/6.6.30/updates/8821au.ko`.

**Image already downloaded and ready to flash:**

```
I:\Source\repos\RapidBeagle\dist\sdcard.img
MD5: fa3311cd7365ba051602c0d05a70c22e
Size: 529 MB
```

**Next step in fresh chat: have user reflash, then verify WiFi end-to-end.**

After flash + boot:

```bash
# Always run before SSH after reflash — fresh sshd host key
ssh-keygen -R 192.168.7.2

# WiFi sanity check
ssh root@192.168.7.2 "lsmod | grep 8821; ip link show wlan0; dmesg | grep -iE 'rtw|wlan|FWFreeToGo' | tail -15"
```

**Three possible outcomes:**

1. **Best case:** `wlan0` exists, dmesg shows successful firmware download (no `FWFreeToGo` failure), `iw wlan0 scan` returns SSIDs. → WiFi works. Move on to overlayfs / cosmetic todos.

2. **Same as before:** `wlan0` exists but dmesg has `_FWFreeToGo: Polling FW ready Fail!`. → Confirmed kernel-6.6 + AM335x MUSB issue with this whole driver lineage. Recommend dongle swap to TL-WN722N v1 (AR9271, mainline `ath9k_htc` already built into our kernel — just need `linux-firmware`). User has alternate dongles.

3. **Different failure:** new dmesg signature → diagnose from there.

Quick scan test (after `wlan0` is up):

```bash
ssh root@192.168.7.2 "ip link set wlan0 up; iw wlan0 scan 2>&1 | grep SSID | head"
```

### Failure-recovery branches

If `_FWFreeToGo` chip-MCU race repeats with morrownr/8821au, the trail of OOT drivers for this dongle is exhausted on this kernel. Two escape hatches:

1. **Different dongle** — TP-Link TL-WN722N v1 (Atheros AR9271) or any MT7601U dongle. Both drivers ALREADY built into our kernel (`CONFIG_ATH9K_HTC=y`, `CONFIG_MT7601U=y` in `linux-fragment.config`). Just plug in, modprobe-free. May need `linux-firmware` for ath9k_htc firmware blob.
2. **Older kernel** — drop kernel from 6.6.30 to e.g. 5.15.x where the aircrack-ng v5.13.6 driver is known to work. Painful regression though — gives up newer subsystem fixes.

User's preference: keep this dongle (option 1 has unused units). Worth one more morrownr/8821au attempt before fallback.

---

## Repo layout (key files)

```
I:\Source\repos\RapidBeagle\
├── docs/
│   ├── BUILD_JOURNAL.md                      ← READ THIS FIRST: 14 pitfalls + PB2 prep
│   ├── HANDOFF_NEXT_CHAT.md                  ← this file
│   └── superpowers/{specs,plans}/            ← original spec & plan docs
├── dist/sdcard.img                           ← latest flashable image (gitignored)
├── optimize-pocketbeagle-boot.sh             ← legacy Approach 1 (Debian script)
├── restore-pocketbeagle-boot.sh
└── buildroot/                                ← Approach 2 (everything below)
    ├── README.md
    ├── FIRST_BUILD_CHECKLIST.md
    ├── external/
    │   ├── external.desc / external.mk / Config.in
    │   ├── configs/rapidbeagle_pb_defconfig  ← BR2_* package selections, 512 MB rootfs
    │   ├── package/rtl8812au/
    │   │   ├── Config.in
    │   │   └── rtl8812au.mk                  ← currently morrownr/8821au-20210708
    │   └── board/rapidbeagle/pocketbeagle/
    │       ├── linux-fragment.config         ← kernel CONFIG_ overrides
    │       ├── uEnv.txt                      ← U-Boot env (silent, quiet loglevel=3)
    │       ├── genimage.cfg                  ← SD partition layout (512 MB rootfs)
    │       ├── post-build.sh                 ← SSH key + sshd hardening + .NET install
    │       ├── post-image.sh                 ← genimage call
    │       └── rootfs-overlay/etc/
    │           ├── inittab                   ← BusyBox init mounts (incl. devpts)
    │           ├── network/interfaces        ← usb0 static, eth0 DHCP
    │           ├── wpa_supplicant.conf       ← empty template, app fills
    │           └── init.d/
    │               ├── S30-load-modules      ← modprobes 8821au (currently)
    │               ├── S39-usb-gadget        ← creates NCM+ECM gadget, stable MACs, ifup usb0
    │               ├── S98-pb-heartbeat      ← USR0 LED state machine
    │               └── S99-app-launcher      ← writes /run/boot-time.log, launches /opt/app/rapidbeagle-app
    └── scripts/
        ├── build.sh
        └── flash-sdcard.sh
```

Recent commits (high-signal — full history is in `git log`):

```
fix(buildroot): morrownr/8821au — re-add _FW_UNDER_SURVEY rename sed hook    ← latest
fix(buildroot): morrownr/8821au — pass CONFIG_RTL8821AU=m
fix(buildroot): switch WiFi driver to morrownr/8821au-20210708
fix(buildroot): switch to aircrack-ng v5.13.6 + cfg80211 6.6 patch    (REVERTED)
fix(buildroot): morrownr/8812au — add Edimax AC600 USB ID            (REVERTED)
fix(buildroot): morrownr/8812au — pass CONFIG_RTL8812AU=m            (REVERTED)
fix(buildroot): switch rtl8812au to morrownr fork                    (REVERTED)
feat(buildroot): add .NET 10 ASP.NET runtime + Realtek 8812AU WiFi driver
docs: add comprehensive build journal for PB1 + PB2 prep
fix(buildroot): pin stable MACs on USB gadget functions
... (full history at https://github.com/kurtnelle/RapidBeagle)
```

---

## Useful one-liners (copy/paste ready)

### Check build status (WSL2)
```bash
ssh -p 2222 root@localhost "ls -la ~/buildroot/output/images/sdcard.img 2>&1 | head -1; ps aux|grep -E 'cc1|^make'|grep -v grep|wc -l; tail -3 /tmp/buildroot-build*.log | tail -3"
```

### Download fresh image to dist/
```bash
scp -P 2222 root@localhost:/root/buildroot/output/images/sdcard.img I:/Source/repos/RapidBeagle/dist/sdcard.img
certutil -hashfile I:/Source/repos/RapidBeagle/dist/sdcard.img MD5
```

### Sync a single file from Windows repo to WSL clone
```bash
scp -P 2222 "I:/Source/repos/RapidBeagle/<path>" root@localhost:/root/RapidBeagle/<path>
ssh -p 2222 root@localhost "sed -i 's/\r\$//' /root/RapidBeagle/<path>"
```

### Sync entire external/ tree (when many files changed)
```bash
cd "I:/Source/repos/RapidBeagle"
tar cf - buildroot/external | ssh -p 2222 root@localhost "cd /root/RapidBeagle && rm -rf buildroot/external && tar xf - && find buildroot/external -type f -exec sed -i 's/\r\$//' {} \;"
```

### Force-rebuild only the rtl8812au package
```bash
ssh -p 2222 root@localhost "cd ~/buildroot && rm -rf output/build/rtl8812au-* output/per-package/rtl8812au && rm -f output/images/sdcard.img output/images/rootfs.* output/images/boot.vfat output/target/lib/modules/6.6.30/updates/*.ko && nohup make -j16 > /tmp/buildroot-build-$(date +%H%M).log 2>&1 &"
```

### Device-side diagnostic for WiFi
```bash
ssh root@192.168.7.2 "lsmod | grep -E '8821|88XX'; ip link show wlan0 2>&1; dmesg | grep -iE 'rtw|FWFreeToGo|FWDL|hal_init|rtl8' | tail -15"
```

### Device-side diagnostic for boot/dotnet
```bash
ssh root@192.168.7.2 "cat /run/boot-time.log; dotnet --info | head -10; uptime"
```

### Serial console (when COM6 free, dongle plugged)
```bash
python "C:\Users\shawn\AppData\Local\Temp\pb-serial.py" "<command>"
```

### Time end-to-end power-on → SSH (PowerShell)
```powershell
$s=Get-Date; do { ssh -o ConnectTimeout=1 -o BatchMode=yes root@192.168.7.2 "true" 2>$null } until ($LASTEXITCODE -eq 0); "{0:N2}s" -f ((Get-Date)-$s).TotalSeconds
```

### Reconfigure Windows NCM adapter IP after reflash (elevated PowerShell)
```powershell
$a = Get-NetAdapter | ? {$_.InterfaceDescription -match 'UsbNcm'} | Select -First 1
Enable-NetAdapter -Name $a.Name -Confirm:$false; Start-Sleep 2
Remove-NetIPAddress -InterfaceIndex $a.ifIndex -Confirm:$false -EA SilentlyContinue
New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress 192.168.7.1 -PrefixLength 24
ping 192.168.7.2
```

(If `$a` is empty: unplug & replug the micro-USB cable for ~3s, run again.)

### Clear stale SSH host key after reflash
```bash
ssh-keygen -R 192.168.7.2
```

---

## Known gotchas to watch for in next session

1. **Stale host key after every reflash.** sshd regenerates host keys at first boot. Always `ssh-keygen -R 192.168.7.2` before retrying SSH.
2. **Windows NCM adapter goes "Disconnected" sometimes after reflash** even with the stable MAC. Re-enable via PowerShell snippet above. Sometimes needs cable unplug/replug to re-trigger Windows enumeration.
3. **COM6 mutual exclusion.** Tera Term and our `pb-serial.py` script can't both have COM6 open. Always close one before using the other.
4. **`set -euo pipefail` traps in post-build.** If a step "silently dies", check whether a pipe failed under pipefail. Most often: `dotnet --list-runtimes` of the cross-arch binary.
5. **Buildroot caching can hide source changes.** If a hook should have applied but didn't seem to, force-rebuild that package with `rm -rf output/build/<pkg>-* output/per-package/<pkg>` THEN `make`.
6. **Launcher task notifications are not build completion.** `nohup ... &` returns immediately. Always re-check `ls sdcard.img` and process count.
7. **Module name varies by fork.** aircrack-ng = `88XXau.ko`, morrownr/8812au = `8812au.ko`, morrownr/8821au = `8821au.ko`. `S30-load-modules` and `MODULE_MAKE_OPTS` (`CONFIG_RTL...`) need to match.

---

## Open todos when handoff happened

1. **Get WiFi working** — morrownr/8821au-20210708 driver compiled cleanly; image (MD5 `fa3311cd...`) is in `dist/` waiting to flash. Step 1 of the new chat is to test it on hardware.
2. **Read-only rootfs + writable data partition** — IN-FLIGHT. The kernel/defconfig/genimage already partly staged for this:
   - `linux-fragment.config` now has `CONFIG_OVERLAY_FS=y`
   - `genimage.cfg` now defines THREE partitions: `boot.vfat` (16 MB), `rootfs.ext4` (256 MB, mounted RO via overlayfs), `data.vfat` (256 MB, FAT32 user-editable from Windows)
   - `defconfig` rootfs size reduced from `512M` → `256M` (app moves to data partition)
   - **Still needed:** `post-image.sh` must stage `BINARIES_DIR/data/config.txt` and `BINARIES_DIR/data/README.txt` (genimage references them); init script `S05-overlay-root` to do the overlay mount + bind `/data` to the FAT partition; possibly relocate `/opt/app` symlink to `/data/app` so Windows users can drop binaries directly via the FAT partition.
3. Polish cosmetic boot warnings (mount /dev EBUSY message, hostname showing as "(none)" at login).
4. Persistent `/etc/ssh/` host keys across reflash (avoid the host-key warning each rebuild) — natural fit with the writable `data` partition once #2 lands.

Beyond those, eventual nice-to-haves:
- Persistent `/etc/ssh/` host keys across reflash (avoids the host-key warning each rebuild)
- Resize rootfs.ext4 to actual content size + slack instead of 512 MB allocated for ~250 MB used
- Dependency check at top of `build.sh` (mtools, dosfstools, gawk, libncurses-dev)
- A `deploy.sh` helper on Windows side that does `dotnet publish -r linux-arm` + scp + restart in one command
