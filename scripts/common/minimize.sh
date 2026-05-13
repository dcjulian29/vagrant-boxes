#!/usr/bin/env bash
# Clean package caches and zero free space so the exported .box is as small
# as possible.  Runs on every OS as the final provisioner step.
set -euo pipefail

echo "==> [minimize] Cleaning package caches..."
if command -v apt-get &>/dev/null; then
  apt-get -y autoremove --purge
  apt-get -y clean
  rm -rf /var/lib/apt/lists/*
elif command -v dnf &>/dev/null; then
  dnf clean all -y
fi

echo "==> [minimize] Removing temporary and log files"
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -name "*.log" -delete
find /var/log -type f -name "*.gz"  -delete
truncate -s 0 /var/log/lastlog 2>/dev/null || true
truncate -s 0 /var/log/wtmp    2>/dev/null || true
truncate -s 0 /var/log/btmp    2>/dev/null || true

echo "==> [minimize] Removing bash history"
unset HISTFILE
rm -f /root/.bash_history /home/vagrant/.bash_history

echo "==> [minimize] Zeroing free space to improve box compression..."
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY
sync

echo "==> [minimize] Minimize complete."
