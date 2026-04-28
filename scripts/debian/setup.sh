#!/usr/bin/env bash
# Debian 13 (Trixie) - OS-specific setup.
# Runs inside the VM after cloud-init has created the vagrant user.
set -euo pipefail

echo "==> [debian] Updating package index..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

echo "==> [debian] Installing base packages..."
apt-get install -y --no-install-recommends \
  openssh-server \
  curl \
  wget \
  sudo \
  bash-completion \
  dbus \
  lsb-release

echo "==> [debian] Enabling SSH service..."
systemctl enable ssh

# Disable predictable NIC naming so Vagrant networking stays simple
ln -sf /dev/null /etc/systemd/network/99-default.link 2>/dev/null || true

echo "==> [debian] Setup complete."
