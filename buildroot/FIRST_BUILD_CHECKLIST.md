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
