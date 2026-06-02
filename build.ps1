$ErrorActionPreference = "Stop"
$onWindows = ($null -eq $IsWindows) -or ($IsWindows -eq $true)

if (-not $onWindows) {
  $platform = if ($IsLinux) { "Linux" } elseif ($IsMacOS) { "macOS" } else { "unknown" }
  Write-Host ""
  Write-Host "ERROR: This script is for Windows (Hyper-V) only." -ForegroundColor Red
  Write-Host "       Detected platform: $platform"              -ForegroundColor Yellow
  Write-Host ""
  Write-Host "       To build on $platform, use build.sh instead:"
  Write-Host "         ./build.sh"
  Write-Host ""
  exit 1
}

& (Join-Path $PSScriptRoot "providers\hyperv\build.ps1")
exit $LASTEXITCODE
