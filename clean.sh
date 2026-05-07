#!/usr/bin/env bash
# =============================================================================
# clean.sh - Clean Build Output Directories (Linux / macOS).
# =============================================================================
set -euo pipefail

rm -rf boxes/
rm -rf tmp/
rm -f *.log
