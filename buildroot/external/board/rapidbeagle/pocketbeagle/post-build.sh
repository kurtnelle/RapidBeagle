#!/usr/bin/env bash
# post-build.sh — runs after rootfs is staged in $TARGET_DIR
#
# Responsibilities:
#   1. Copy user's SSH public key into /root/.ssh/authorized_keys
#   2. Harden /etc/ssh/sshd_config (disable password auth, limit root login)
#   3. Ensure /opt/app/ exists for app deployment
#
# Buildroot calls this with $TARGET_DIR as $1.
# Set RAPIDBEAGLE_SSH_PUBKEY env var to override the default key path.

set -euo pipefail

TARGET_DIR="$1"
PUBKEY_SRC="${RAPIDBEAGLE_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

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

echo "post-build: complete."
