#!/usr/bin/env bash
# Install the Vagrant insecure public key and configure passwordless sudo.
# Runs on every OS after the OS-specific setup script.
set -euo pipefail

echo "==> [common] Configuring vagrant user..."

mkdir -pm 700 /home/vagrant/.ssh

# Fetch the well-known Vagrant insecure public key
curl -fsSL \
  https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub \
  >> /home/vagrant/.ssh/authorized_keys

chmod 600 /home/vagrant/.ssh/authorized_keys
chown -R vagrant:vagrant /home/vagrant/.ssh

echo "vagrant ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vagrant
chmod 440 /etc/sudoers.d/vagrant

echo "==> [common] vagrant user configured."
