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
