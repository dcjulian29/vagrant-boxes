#!/usr/bin/env bash
# Debian specific post-boot configuration.
# Runs inside the VM after cloud-init has created the vagrant user.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> [debian] Updating package lists and upgrading"
apt-get update -y
apt-get upgrade -y

echo "==> [debian] Enabling and starting SSH service..."
systemctl enable ssh
systemctl start  ssh || true

# Disable predictable NIC naming so Vagrant networking stays simple
ln -sf /dev/null /etc/systemd/network/99-default.link 2>/dev/null || true

echo "==> [debian] Setup complete."
