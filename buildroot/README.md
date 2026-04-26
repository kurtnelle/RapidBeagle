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
