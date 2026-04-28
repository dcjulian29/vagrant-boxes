#!/usr/bin/env bash
# Clean package caches and zero free space so the exported .box is as small
# as possible.  Runs on every OS as the final provisioner step.
set -euo pipefail

echo "==> [common] Cleaning package caches..."
if command -v apt-get &>/dev/null; then
  apt-get -y autoremove --purge
  apt-get -y clean
  rm -rf /var/lib/apt/lists/*
elif command -v dnf &>/dev/null; then
  dnf clean all
fi

echo "==> [common] Zeroing free space to improve box compression..."
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY
sync

echo "==> [common] Minimize complete."
