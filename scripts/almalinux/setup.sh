#!/usr/bin/env bash
# AlmaLinux 10 - OS-specific setup.
# Runs inside the VM after cloud-init has created the vagrant user.
set -euo pipefail

echo "==> [almalinux] Installing base packages..."
dnf install -y \
  openssh-server \
  curl \
  wget \
  sudo \
  bash-completion \
  NetworkManager

echo "==> [almalinux] Enabling services..."
systemctl enable sshd
systemctl enable NetworkManager

echo "==> [almalinux] Setting SELinux to permissive for Vagrant compatibility..."
sed -i "s/^SELINUX=enforcing/SELINUX=permissive/" /etc/selinux/config || true

echo "==> [almalinux] Setup complete."
