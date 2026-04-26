#!/usr/bin/env bash
# post-build.sh — runs after rootfs is staged in $TARGET_DIR
#
# Responsibilities:
#   1. Copy user's SSH public key into /root/.ssh/authorized_keys
#   2. Harden /etc/ssh/sshd_config (disable password auth, limit root login)
#   3. Ensure /opt/app/ exists for app deployment
#   4. Install .NET 10 ASP.NET Core runtime to /opt/dotnet
#
# Buildroot calls this with $TARGET_DIR as $1.
# Set RAPIDBEAGLE_SSH_PUBKEY env var to override the default key path.
# Set RAPIDBEAGLE_SKIP_DOTNET=1 to skip the .NET install (tiny image).

set -euo pipefail

TARGET_DIR="$1"
PUBKEY_SRC="${RAPIDBEAGLE_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
SKIP_DOTNET="${RAPIDBEAGLE_SKIP_DOTNET:-0}"

# ── Step 1: SSH authorized_keys ──────────────────────────────────────────────
if [[ ! -f "$PUBKEY_SRC" ]]; then
    echo "post-build: WARNING: SSH public key not found at $PUBKEY_SRC"
    echo "post-build: WARNING: SSH key auth will not be set up."
    echo "post-build: WARNING: Set RAPIDBEAGLE_SSH_PUBKEY env var to override."
else
    mkdir -p "$TARGET_DIR/root/.ssh"
    chmod 700 "$TARGET_DIR/root/.ssh"
    cp "$PUBKEY_SRC" "$TARGET_DIR/root/.ssh/authorized_keys"
    chmod 600 "$TARGET_DIR/root/.ssh/authorized_keys"
    echo "post-build: installed SSH key from $PUBKEY_SRC"
fi

# ── Step 2: Harden sshd_config ───────────────────────────────────────────────
SSHD_CONFIG="$TARGET_DIR/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    echo "post-build: hardened sshd_config (no password, root key-only)"
fi

# ── Step 3: Ensure /opt/app exists ───────────────────────────────────────────
mkdir -p "$TARGET_DIR/opt/app"
echo "post-build: /opt/app/ ready for app deployment"

# ── Step 4: Mark scripts executable (defensive — they should already be) ────
for script in "$TARGET_DIR/etc/init.d"/S*; do
    [[ -f "$script" ]] && chmod +x "$script"
done

# ── Step 5: Install .NET 10 ASP.NET Core runtime to /opt/dotnet ──────────────
# Idempotent — re-uses cached tarball in Buildroot's dl/ if present.
# Architecture-aware: linux-arm for PocketBeagle 1, linux-arm64 for PB2.

if [[ "$SKIP_DOTNET" == "1" ]]; then
    echo "post-build: RAPIDBEAGLE_SKIP_DOTNET=1 — skipping .NET runtime install"
else
    # Detect architecture from a target-installed binary
    if file -b "$TARGET_DIR/bin/busybox" 2>/dev/null | grep -q "ARM aarch64"; then
        DOTNET_ARCH="arm64"
    elif file -b "$TARGET_DIR/bin/busybox" 2>/dev/null | grep -q "ARM"; then
        DOTNET_ARCH="arm"
    else
        echo "post-build: WARNING: could not detect target arch — defaulting to linux-arm"
        DOTNET_ARCH="arm"
    fi

    DOTNET_CHANNEL="10.0"
    DL_CACHE="${HOME}/buildroot/dl/dotnet"
    INSTALL_DIR="$TARGET_DIR/opt/dotnet"

    mkdir -p "$DL_CACHE" "$INSTALL_DIR"

    # Fetch (and cache) Microsoft's install script
    INSTALL_SCRIPT="$DL_CACHE/dotnet-install.sh"
    if [[ ! -f "$INSTALL_SCRIPT" ]]; then
        echo "post-build: downloading dotnet-install.sh ..."
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$INSTALL_SCRIPT"
        chmod +x "$INSTALL_SCRIPT"
    fi

    # Skip the install if /opt/dotnet/dotnet already exists from a previous
    # build's incremental output (Buildroot reuses TARGET_DIR between builds).
    if [[ -x "$INSTALL_DIR/dotnet" ]]; then
        DOTNET_VER="$("$INSTALL_DIR/dotnet" --list-runtimes 2>/dev/null | grep '^Microsoft.AspNetCore.App' | head -1 | awk '{print $2}')"
        echo "post-build: .NET ${DOTNET_VER:-?} already in $INSTALL_DIR — skipping install"
    else
        echo "post-build: installing .NET ${DOTNET_CHANNEL} ASP.NET runtime (linux-${DOTNET_ARCH}) ..."
        # The install script downloads to its own cache; we point it at our DL_CACHE
        # so re-builds don't re-download.
        export DOTNET_INSTALL_DIR="$INSTALL_DIR"
        "$INSTALL_SCRIPT" \
            --runtime aspnetcore \
            --channel "$DOTNET_CHANNEL" \
            --architecture "$DOTNET_ARCH" \
            --install-dir "$INSTALL_DIR" \
            --no-path \
            --verbose
        echo "post-build: .NET runtime installed to /opt/dotnet ($(du -sh "$INSTALL_DIR" | cut -f1))"
    fi

    # Symlink so `dotnet` is on $PATH on the device
    mkdir -p "$TARGET_DIR/usr/bin"
    ln -sf /opt/dotnet/dotnet "$TARGET_DIR/usr/bin/dotnet"

    # Profile drop-in for DOTNET_ROOT — some apps need it explicitly
    cat > "$TARGET_DIR/etc/profile.d/dotnet.sh" <<'PROFILE'
# .NET runtime paths
export DOTNET_ROOT=/opt/dotnet
PROFILE
fi

echo "post-build: complete."
