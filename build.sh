#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo ""
  echo "ERROR: This script is for Linux only." >&2
  echo "       Detected platform: $(uname -s)" >&2
  echo ""
  echo "       On Windows, use build.ps1 instead." >&2
  echo ""
  exit 1
fi

FAILED=""

echo "==> Running libvirt build..."
if ! bash "$SCRIPT_DIR/providers/libvirt/build.sh"; then
  FAILED="$FAILED libvirt"
fi

echo "==> Running virtualbox build..."
if ! bash "$SCRIPT_DIR/providers/virtualbox/build.sh"; then
  FAILED="$FAILED virtualbox"
fi

echo ""
echo "-----"
echo ""

if [[ -n "$FAILED" ]]; then
  echo "The following provider builds failed:$FAILED" >&2
  exit 1
else
  echo "All builds completed successfully."
fi
