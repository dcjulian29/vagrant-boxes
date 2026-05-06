# =============================================================================
# clean.ps1 - Clean Build Output Directories (Windows).
# =============================================================================

Remove-Item -Path "boxes"        -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "packer_cache" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "tmp"          -Recurse -Force -ErrorAction SilentlyContinue
