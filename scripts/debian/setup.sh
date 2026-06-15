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

# Re-assert cloud-init network disable in case apt-get upgrade reset it
mkdir -p /etc/cloud/cloud.cfg.d
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network.cfg
sed -i 's/^ - networking$/ # - networking/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Ensure systemd-networkd is the active network manager
systemctl enable systemd-networkd
systemctl enable systemd-resolved

echo "==> [debian] Setup complete."
