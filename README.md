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
