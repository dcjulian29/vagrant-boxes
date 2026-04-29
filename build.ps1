# =============================================================================
# build.ps1 - Build VirtualBox Vagrant boxes locally (Windows).
#
# Usage:
#   .\build.ps1                               Build all registered OSes
#   .\build.ps1 -OS debian-13                 Build a single OS
#   .\build.ps1 -OS debian-13 -Version 13.1.20260428  Explicit version
#
# The version defaults to today's date (yyyyMMdd) when not supplied.
# Converted OVAs and the cloud-init ISO are cached in tmp\ - delete the
# relevant file to force a refresh.
# =============================================================================
param(
  [string]$OS = "all",
  [string]$Version = (Get-Date -Format "yyyyMMdd")
)

$ErrorActionPreference = "Stop"

# =============================================================================
# OS REGISTRY
# -----------------------------------------------------------------------------
# To add a new OS:
#   1. Add an entry to $CloudImgUrl   with the qcow2 download URL
#   2. Add an entry to $VBoxOsType    with the VBoxManage OS type
#   3. Add the name to $OsOrder       to control build sequence
#   4. Create os\<name>.pkrvars.hcl    (copy and edit an existing one)
#   5. Create os\<name>.Vagrantfile    (copy and edit an existing one)
#   6. Create scripts\<family>\setup.sh  (or reuse an existing family script)
# =============================================================================
$CloudImgUrl = @{
  "debian-13"    = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
  "almalinux-10" = "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
}

$VBoxOsType = @{
  "debian-13"    = "Debian_64"
  "almalinux-10" = "RedHat_64"
}

# Explicit order for "build all" so output is predictable
$OsOrder = @("debian-13", "almalinux-10")

# =============================================================================

function Resolve-ToolPaths {
  $searchDirs = @(
    "C:\Program Files\Oracle\VirtualBox",
    "C:\Program Files\Oracle\VM VirtualBox",
    "C:\Program Files\qemu",
    "C:\ProgramData\chocolatey\bin"
  )

  foreach ($dir in $searchDirs) {
    if ((Test-Path $dir) -and ($env:PATH -notlike "*$dir*")) {
      $env:PATH = "$dir;$env:PATH"
    }
  }
}

function Test-Prerequisites {
  $missing = @()

  if (-not (Get-Command packer     -ErrorAction SilentlyContinue)) { $missing += "packer      -> choco install packer" }
  if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) { $missing += "VBoxManage  -> choco install virtualbox" }
  if (-not (Get-Command qemu-img   -ErrorAction SilentlyContinue)) { $missing += "qemu-img    -> choco install qemu" }

  if ($missing.Count -gt 0) {
    Write-Host "ERROR: The following tools could not be found even after checking known install paths:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "If you just installed these via Chocolatey, open a new"
    Write-Host "PowerShell window and try again - PATH is not updated in open sessions."
    exit 1
  }
}

# ---- Cloud-init seed ISO creation -------------------------------------------
function New-CloudInitISO {
  param([string]$SourceDir, [string]$OutputPath)

  if (Test-Path $OutputPath) {
    Write-Host "==> Using cached cloud-init ISO: $OutputPath"
    return
  }

  Write-Host "==> Creating cloud-init seed ISO..."

  if (-not ([System.Management.Automation.PSTypeName]"ComIStreamWrapper").Type) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public class ComIStreamWrapper : Stream {
    private readonly IStream _stream;
    public ComIStreamWrapper(object comObject) { _stream = (IStream)comObject; }
    public override bool CanRead  { get { return true;  } }
    public override bool CanSeek  { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length   { get { throw new NotSupportedException(); } }
    public override long Position {
        get { throw new NotSupportedException(); }
        set { throw new NotSupportedException(); }
    }

    public override int Read(byte[] buffer, int offset, int count) {
        byte[] tmp = (offset == 0) ? buffer : new byte[count];
        IntPtr cbRead = Marshal.AllocHGlobal(4);
        try {
            _stream.Read(tmp, count, cbRead);
            int n = Marshal.ReadInt32(cbRead);
            if (offset != 0 && n > 0) { Array.Copy(tmp, 0, buffer, offset, n); }
            return n;
        } finally { Marshal.FreeHGlobal(cbRead); }
    }

    public override void Write(byte[] b, int o, int c) { throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long o, SeekOrigin r)    { throw new NotSupportedException(); }
    public override void SetLength(long v)             { throw new NotSupportedException(); }
}
'@
  }

  $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
  try {
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
    $fsi.VolumeName = "cidata"

    if (-not [System.IO.Path]::IsPathRooted($SourceDir)) {
      $SourceDir = Join-Path (Get-Location).Path $SourceDir
    }

    $fsi.Root.AddTreeWithNamedStreams($SourceDir, $false)
    $result = $fsi.CreateResultImage()

    try {
      $istream = $result.ImageStream
      $wrapper = New-Object ComIStreamWrapper($istream)

      if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path $OutputPath
      }

    $outFile = [System.IO.File]::Create($OutputPath)

      try {
        $wrapper.CopyTo($outFile)
      } finally {
        $outFile.Close()
      }

      [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($istream)
    } finally {
      [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($result)
    }
  } finally {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
  }

  Write-Host "==> Cloud-init seed ISO created: $OutputPath"
}

function Invoke-PrepareImage {
  param([string]$Name)

  $url = $CloudImgUrl[$Name]
  $osType = $VBoxOsType[$Name]
  $qcow2 = "tmp\$Name.qcow2"
  $vmdk = "tmp\$Name.vmdk"
  $ova = "tmp\$Name.ova"

  New-Item -ItemType Directory -Force -Path "tmp" | Out-Null

  if (Test-Path $ova) {
    Write-Host "==> [$Name] Cached OVA found - skipping download."
    Write-Host "    Delete $ova to force a fresh download."
    return
  }

  Write-Host ""
  Write-Host "==> [$Name] Downloading cloud image..."
  Write-Host "    $url"

  curl.exe -fL --progress-bar $url -o $qcow2

  Write-Host "==> [$Name] Converting qcow2 -> VMDK..."
  qemu-img convert -p -f qcow2 -O vmdk $qcow2 $vmdk
  Remove-Item $qcow2 -Force -ErrorAction SilentlyContinue

  Write-Host "==> [$Name] Creating OVA..."
  $tmpVm = "$Name-prep-$PID"
  $cwd = (Get-Location).Path

  $null = VBoxManage unregistervm $tmpVm --delete 2>&1

  VBoxManage createvm --name $tmpVm --ostype $osType --register
  VBoxManage storagectl $tmpVm --name "SATA" --add sata
  VBoxManage storageattach $tmpVm `
    --storagectl "SATA" --port 0 --device 0 `
    --type hdd --medium "$cwd\$vmdk"
  VBoxManage export $tmpVm --output "$cwd\$ova"
  VBoxManage unregistervm $tmpVm --delete
  Remove-Item $vmdk -Force -ErrorAction SilentlyContinue

  Write-Host "==> [$Name] OVA ready: $ova"
}

function Invoke-BuildBox {
  param([string]$Name, [string]$CidataIso)

  Write-Host ""
  Write-Host "------------------------------------------------------------"
  Write-Host "  OS      : $Name"
  Write-Host "  Version : $Version"
  Write-Host "  Output  : boxes\$Name-$Version-virtualbox.box"
  Write-Host "------------------------------------------------------------"

  Invoke-PrepareImage -Name $Name
  New-Item -ItemType Directory -Force -Path "boxes" | Out-Null

  Write-Host "==> [$Name] Removing any leftover Packer VMs..."
  $null = VBoxManage controlvm "$Name-packer" poweroff 2>&1
  Start-Sleep -Seconds 2
  $null = VBoxManage unregistervm "$Name-packer" --delete 2>&1

  Start-Sleep -Seconds 5

  Write-Host ""
  Write-Host "==> [$Name] Initializing Packer plugins..."

  packer init packer/virtualbox.pkr.hcl
  if ($LASTEXITCODE -ne 0) {
    throw "packer init failed with exit code $LASTEXITCODE"
  }

  Write-Host "==> [$Name] Running Packer build..."
  Write-Host "    cidata_iso = $CidataIso"

  packer build `
    -var "version=$Version" `
    -var "cidata_iso=$CidataIso" `
    -var-file="os/$Name.pkrvars.hcl" `
    packer/virtualbox.pkr.hcl

  if ($LASTEXITCODE -ne 0) {
    throw "Packer build failed with exit code $LASTEXITCODE"
  }

  Write-Host ""
  Write-Host "==> [$Name] Complete -> boxes\$Name-$Version-virtualbox.box"
}

# =============================================================================

Resolve-ToolPaths
Test-Prerequisites

New-Item -ItemType Directory -Force -Path "tmp" | Out-Null
New-CloudInitISO -SourceDir "cloud-init" -OutputPath "tmp\cidata.iso"

$cidataIsoPath = Join-Path (Get-Location).Path "tmp\cidata.iso"

if ($OS -eq "all") {
    $BuildList = $OsOrder
}
else {
    if (-not $CloudImgUrl.ContainsKey($OS)) {
        Write-Host "ERROR: Unknown OS '$OS'. Available: $([string]::Join(', ', $OsOrder))" -ForegroundColor Red
        exit 1
    }
    $BuildList = @($OS)
}

Write-Host ""
Write-Host "=== Vagrant Box Builder (VirtualBox) ==="
Write-Host "Targets : $($BuildList -join ', ')"
Write-Host "Version : $Version"

$failed = [System.Collections.Generic.List[string]]::new()

foreach ($osName in $BuildList) {
  try {
    Invoke-BuildBox -Name $osName -CidataIso $cidataIsoPath
    Write-Host "OK : $osName" -ForegroundColor Green
  } catch {
    Write-Host "FAILED : $osName ($_)" -ForegroundColor Red
    $failed.Add($osName)
  }
}

Write-Host ""

if ($failed.Count -gt 0) {
  Write-Host "The following builds failed: $($failed -join ', ')" -ForegroundColor Red
  exit 1
} else {
  Write-Host "All builds completed successfully." -ForegroundColor Green
  Write-Host ""
  Write-Host "Generated boxes:"

  $BuildList | ForEach-Object { Write-Host "  boxes\$_-$Version-virtualbox.box" }
}
