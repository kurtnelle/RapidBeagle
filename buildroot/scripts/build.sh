#!/usr/bin/env bash
# build.sh — RapidBeagle Buildroot build wrapper
#
# Usage:
#   ./build.sh                # configure (if needed) and build
#   ./build.sh defconfig      # apply rapidbeagle_pb_defconfig only
#   ./build.sh menuconfig     # open Buildroot's menuconfig
#   ./build.sh clean          # clean build artifacts
#   ./build.sh distclean      # nuke .config too (full reset)
#
# Env:
#   BUILDROOT_DIR              path to Buildroot clone (default: $HOME/buildroot)
#   RAPIDBEAGLE_SSH_PUBKEY     path to SSH pubkey for image (default: $HOME/.ssh/id_ed25519.pub)
#   RAPIDBEAGLE_DIST_DIR       Windows dist dir via WSL2 mount (default: /mnt/i/Source/repos/RapidBeagle/dist)
#   J                          parallel jobs (default: $(nproc))

set -euo pipefail

# ── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDROOT_EXT_DIR="$(dirname "$SCRIPT_DIR")/external"
BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/buildroot}"
DEFCONFIG="rapidbeagle_pb_defconfig"
RAPIDBEAGLE_DIST_DIR="${RAPIDBEAGLE_DIST_DIR:-/mnt/i/Source/repos/RapidBeagle/dist}"
J="${J:-$(nproc 2>/dev/null || echo 2)}"

# ── Sanity checks ────────────────────────────────────────────────────────────
if [[ ! -d "$BUILDROOT_DIR" ]]; then
    echo "ERROR: Buildroot not found at $BUILDROOT_DIR" >&2
    echo "Clone it first:  git clone https://git.busybox.net/buildroot $BUILDROOT_DIR" >&2
    echo "Or set BUILDROOT_DIR to override the path." >&2
    exit 1
fi

if [[ ! -d "$BUILDROOT_EXT_DIR" ]]; then
    echo "ERROR: External tree not found at $BUILDROOT_EXT_DIR" >&2
    exit 1
fi

# ── Export env vars Buildroot/scripts will read ──────────────────────────────
export BR2_EXTERNAL="$BUILDROOT_EXT_DIR"
export RAPIDBEAGLE_SSH_PUBKEY="${RAPIDBEAGLE_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

cd "$BUILDROOT_DIR"

case "${1:-build}" in
    defconfig)
        make BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"
        ;;
    menuconfig)
        # Apply defconfig first if .config doesn't exist
        [[ -f .config ]] || make BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"
        make menuconfig
        ;;
    clean)
        make clean
        ;;
    distclean)
        make distclean
        ;;
    build|all)
        # Apply defconfig if not yet configured
        if [[ ! -f .config ]]; then
            echo "build.sh: applying $DEFCONFIG (first build)"
            make BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"
        fi
        echo "build.sh: building with -j$J ..."
        make -j"$J"
        echo ""
        echo "================================================================"
        echo "build.sh: BUILD COMPLETE"
        echo "  Image: $BUILDROOT_DIR/output/images/sdcard.img"
        echo "  Flash: sudo $SCRIPT_DIR/flash-sdcard.sh /dev/sdX"
        echo "================================================================"
        echo "build.sh: copying image → $RAPIDBEAGLE_DIST_DIR/sdcard.img"
        mkdir -p "$RAPIDBEAGLE_DIST_DIR"
        cp "$BUILDROOT_DIR/output/images/sdcard.img" "$RAPIDBEAGLE_DIST_DIR/sdcard.img"
        echo "build.sh: copy done ($(du -h "$RAPIDBEAGLE_DIST_DIR/sdcard.img" | cut -f1))"
        ;;
    *)
        echo "Usage: $0 [defconfig|menuconfig|build|clean|distclean]" >&2
        exit 1
        ;;
esac
