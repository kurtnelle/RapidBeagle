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
