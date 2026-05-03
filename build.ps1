# =============================================================================
# build.ps1 - Build Vagrant boxes locally (Windows).
#
# Usage:
#   .\build.ps1                                     Build all OSes (Hyper-V)
#   .\build.ps1 -OS debian-13                       Build a single OS
#   .\build.ps1 -OS debian-13 -Version 13.1.20260428  Explicit version
#   .\build.ps1 -Provider virtualbox                Build VirtualBox boxes
#   .\build.ps1 -Provider hyperv                    Build Hyper-V boxes (default)
#
# The version defaults to today's date (yyyyMMdd) when not supplied.
# Converted VHDXs/OVAs and the cloud-init ISO are cached in tmp\ - delete the
# relevant file to force a refresh.
# =============================================================================
param(
  [string]$OS = "all",
  [string]$Version = (Get-Date -Format "yyyyMMdd"),
  [ValidateSet("hyperv", "virtualbox")]
  [string]$Provider = "hyperv"
)

$ErrorActionPreference = "Stop"

# =============================================================================
# OS REGISTRY
# -----------------------------------------------------------------------------
# To add a new OS:
#   1. Add an entry to $CloudImgUrl with the qcow2 download URL
#   2. Add an entry to $VBoxOsType with the VBoxManage OS type (virtualbox only)
#   3. Add the name to $OsOrder to control build sequence
#   4. Create os/<name>.pkrvars.hcl         (copy and edit an existing one)
#   5. Create os/<name>-hyperv.Vagrantfile  (copy and edit an existing one)
#   6. Create os/<name>.Vagrantfile         (for virtualbox)
#   7. Create scripts\<family>\setup.sh     (or reuse an existing family script)
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

  if (-not (Get-Command packer        -ErrorAction SilentlyContinue)) { $missing += "packer      -> choco install packer" }
  if (-not (Get-Command qemu-img      -ErrorAction SilentlyContinue)) { $missing += "qemu-img    -> choco install qemu" }

  if ($Provider -eq "virtualbox") {
    if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) { $missing += "VBoxManage  -> choco install virtualbox" }
  }

  if ($missing.Count -gt 0) {
    Write-Host "ERROR: The following tools could not be found even after checking known install paths:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "If you just installed these via Chocolatey, open a new"
    Write-Host "PowerShell window and try again - PATH is not updated in open sessions."
    exit 1
  }
}

function Get-HyperVDaemonsInstallCmd {
    param([string]$Name)

    switch ($Name) {
        "debian-13" {
            return "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y hyperv-daemons"
        }
        "almalinux-10" {
            return "sudo dnf makecache -q && sudo dnf install -y hyperv-daemons"
        }
        default { throw "No hyperv-daemons install command defined for OS: $Name" }
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

# ---- Prepare: download cloud image and convert for the target provider ------
function Invoke-PrepareImage {
  param([string]$Name)

  $url = $CloudImgUrl[$Name]
  $qcow2 = "tmp\$Name.qcow2"

  New-Item -ItemType Directory -Force -Path "tmp" | Out-Null

  if ($Provider -eq "hyperv") {
    $vmcxDir = "tmp\$Name-vmcx"

    if (Test-Path $vmcxDir) {
      Write-Host "==> [$Name] Cached VMCX export found - skipping download."
      Write-Host "    Delete $vmcxDir to force a fresh download."
      return
    }

    $qcow2   = "tmp\$Name.qcow2"
    $vhdx    = "tmp\$Name.vhdx"
    $tmpVm   = "$Name-prep"

    Write-Host ""
    Write-Host "==> [$Name] Downloading cloud image..."
    Write-Host "    $url"
    curl.exe -fL --progress-bar $url -o $qcow2

    Write-Host "==> [$Name] Converting qcow2 -> VHDX..."
    qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic $qcow2 $vhdx
    Remove-Item $qcow2 -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $vhdx)) {
      throw "VHDX conversion failed - file not found: $vhdx"
    }

    # qemu-img produces NTFS sparse files; Hyper-V requires non-sparse VHDXs.
    Write-Host "==> [$Name] Materializing VHDX (removing NTFS sparse attribute)..."
    $vhdxFull = "${vhdx}.full"
    try {
        $srcStream = [System.IO.File]::OpenRead($vhdx)
        $dstStream = [System.IO.File]::Create($vhdxFull)
        $srcStream.CopyTo($dstStream)
    } finally {
        if ($null -ne $srcStream) { $srcStream.Dispose() }
        if ($null -ne $dstStream) { $dstStream.Dispose() }
    }
    Remove-Item $vhdx -Force
    Rename-Item $vhdxFull (Split-Path $vhdx -Leaf)

    $absVhdx   = (Resolve-Path $vhdx).Path
    $absTmpDir = (Resolve-Path "tmp").Path

    Write-Host "==> [$Name] VHDX ready: $absVhdx"

    # ---- Vagrant insecure key (needed to SSH into prep VM) ----
    $keyPath = Join-Path $absTmpDir "vagrant_insecure_key"
    if (-not (Test-Path $keyPath)) {
      Write-Host "==> [$Name] Downloading vagrant insecure private key..."
      curl.exe -fsSL -o $keyPath "https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant"
      icacls $keyPath /inheritance:r          | Out-Null
      icacls $keyPath /grant:r "${env:USERNAME}:(R)" | Out-Null
    }

    Write-Host "==> [$Name] Creating temporary Hyper-V VM..."

    # Clean up any leftover temp VM from a previous failed run
    $null = Stop-VM  -Name $tmpVm -TurnOff -Force  -ErrorAction SilentlyContinue
    $null = Remove-VM -Name $tmpVm -Force -ErrorAction SilentlyContinue

    New-VM -Name $tmpVm -Generation 2 -VHDPath $absVhdx -MemoryStartupBytes 1GB `
      -SwitchName "Default Switch" | Out-Null
    Set-VM -Name $tmpVm -AutomaticCheckpointsEnabled $false
    Set-VMFirmware  -VMName $tmpVm -EnableSecureBoot Off
    Set-VMProcessor -VMName $tmpVm -Count 2
    Set-VMMemory    -VMName $tmpVm -DynamicMemoryEnabled $false
    Add-VMDvdDrive  -VMName $tmpVm -Path $CidataIso

    Write-Host "==> [$Name] Starting temp VM to install hyperv-daemons..."
    Start-VM -Name $tmpVm | Out-Null

    Start-Sleep -Seconds 5

    $vmMac       = (Get-VM $tmpVm | Get-VMNetworkAdapter).MacAddress
    $formattedMac = ($vmMac -split '(.{2})' -ne '') -join "-"

    Write-Host "==> [$Name] Waiting for VM to obtain an IP (MAC: $formattedMac)..."
    $vmIP  = $null
    $until = [DateTime]::Now.AddMinutes(5)
    while ([DateTime]::Now -lt $until) {
      $n = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.LinkLayerAddress -eq $formattedMac -and $_.State -ne 'Unreachable' }
      if ($n) { $vmIP = $n.IPAddress; break }
      Start-Sleep -Seconds 5
    }

    if (-not $vmIP) { throw "Timed out waiting for VM IP (5 min)" }

    Write-Host "==> [$Name] VM IP: $vmIP"

    Write-Host "==> [$Name] Waiting for SSH port to open on $vmIP..."
    $until = [DateTime]::Now.AddMinutes(5)
    while ([DateTime]::Now -lt $until) {
      $tcp = New-Object System.Net.Sockets.TcpClient
      try   { $tcp.Connect($vmIP, 22); if ($tcp.Connected) { break } }
      catch { }
      finally { $tcp.Dispose() }
      Start-Sleep -Seconds 5
    }

    Write-Host "==> [$Name] Waiting for vagrant SSH login (cloud-init completing)..."
    $sshOpts = @("-i", $keyPath, "-o", "StrictHostKeyChecking=no",
                  "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10")
    $until = [DateTime]::Now.AddMinutes(5)
    while ([DateTime]::Now -lt $until) {
      $out = ssh @sshOpts "vagrant@$vmIP" "echo ready" 2>&1
      if ($LASTEXITCODE -eq 0) { break }
      Start-Sleep -Seconds 10
    }

    if ($LASTEXITCODE -ne 0) { throw "Timed out waiting for vagrant login on $vmIP" }

    Write-Host "==> [$Name] Installing hyperv-daemons..."

    $installCmd = Get-HyperVDaemonsInstallCmd -Name $Name
    ssh @sshOpts "vagrant@$vmIP" $installCmd
    if ($LASTEXITCODE -ne 0) { throw "hyperv-daemons install failed" }

    Write-Host "==> [$Name] Resetting cloud-init state..."
    ssh @sshOpts "vagrant@$vmIP" "sudo cloud-init clean --machine-id"

    Write-Host "==> [$Name] Shutting down temp VM..."
    ssh @sshOpts "vagrant@$vmIP" "sudo shutdown -h now" 2>&1 | Out-Null
    $until = [DateTime]::Now.AddMinutes(3)
    while ([DateTime]::Now -lt $until -and (Get-VM $tmpVm).State -ne 'Off') {
      Start-Sleep -Seconds 5
    }

    if ((Get-VM $tmpVm).State -ne 'Off') { Stop-VM -Name $tmpVm -TurnOff -Force }

    Get-VMDvdDrive -VMName $tmpVm | Remove-VMDvdDrive -ErrorAction SilentlyContinue

    Write-Host "==> [$Name] Exporting VM to $vmcxDir..."
    Export-VM -Name $tmpVm -Path $absTmpDir
    Rename-Item -Path (Join-Path $absTmpDir $tmpVm) -NewName "$Name-vmcx"

    Write-Host "==> [$Name] Removing temporary VM and source VHDX..."
    Remove-VM -Name $tmpVm -Force
    Remove-Item $vhdx -Force -ErrorAction SilentlyContinue

    Write-Host "==> [$Name] VMCX export ready: $vmcxDir"
  } else {
    $vmdk = "tmp\$Name.vmdk"
    $ova = "tmp\$Name.ova"

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

    VBoxManage createvm --name $tmpVm --ostype $VBoxOsType[$Name] --register
    VBoxManage storagectl $tmpVm --name "SATA" --add sata
    VBoxManage storageattach $tmpVm `
      --storagectl "SATA" --port 0 --device 0 `
      --type hdd --medium "$cwd\$vmdk"
    VBoxManage export $tmpVm --output "$cwd\$ova"
    VBoxManage unregistervm $tmpVm --delete
    Remove-Item $vmdk -Force -ErrorAction SilentlyContinue

    Write-Host "==> [$Name] OVA ready: $ova"
  }
}

function Invoke-BuildBox {
  param([string]$Name, [string]$CidataIso)

  if ($Provider -eq "hyperv") {
    $template = "packer/hyperv.pkr.hcl"
    $boxSuffix = "hyperv"
  }
  else {
    $template = "packer/virtualbox.pkr.hcl"
    $boxSuffix = "virtualbox"
  }

  Write-Host ""
  Write-Host "------------------------------------------------------------"
  Write-Host " OS       : $Name"
  Write-Host " Provider : $Provider"
  Write-Host " Version  : $Version"
  Write-Host " Output   : boxes\$Name-$Version-$boxSuffix.box"
  Write-Host "------------------------------------------------------------"

  Invoke-PrepareImage -Name $Name -CidataIso $CidataIso
  New-Item -ItemType Directory -Force -Path "boxes" | Out-Null

  Write-Host "==> [$Name] Removing any leftover Packer VMs ($Provider)..."
  if ($Provider -eq "hyperv") {
    Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 2
    Remove-VM -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 5
  } else {
    $null = VBoxManage controlvm "$Name-packer" poweroff 2>&1
    Start-Sleep -Seconds 2
    $null = VBoxManage unregistervm "$Name-packer" --delete 2>&1
    Start-Sleep -Seconds 5
  }

  Write-Host ""
  Write-Host "==> [$Name] Initializing Packer plugins..."

  packer init $template
  if ($LASTEXITCODE -ne 0) {
    throw "packer init failed with exit code $LASTEXITCODE"
  }

  Write-Host "==> [$Name] Running Packer build ($Provider)..."
  Write-Host "    cidata_iso = $CidataIso"

  packer build `
    -var "version=$Version" `
    -var "cidata_iso=$CidataIso" `
    -var-file="os/$Name.pkrvars.hcl" `
    $template

  if ($LASTEXITCODE -ne 0) {
    throw "Packer build failed with exit code $LASTEXITCODE"
  }

  Write-Host ""
  Write-Host "==> [$Name] Complete -> boxes\$Name-$Version-$boxSuffix.box"
}

# =============================================================================

Resolve-ToolPaths
Test-Prerequisites

New-Item -ItemType Directory -Force -Path "tmp" | Out-Null
New-CloudInitISO -SourceDir "cloud-init" -OutputPath "tmp\cidata.iso"

$cidataIsoPath = Join-Path (Get-Location).Path "tmp\cidata.iso"

if ($OS -eq "all") {
  $BuildList = $OsOrder
} else {
  if (-not $CloudImgUrl.ContainsKey($OS)) {
    Write-Host "ERROR: Unknown OS '$OS'. Available: $([string]::Join(', ', $OsOrder))" -ForegroundColor Red
    exit 1
  }

  $BuildList = @($OS)
}

Write-Host ""
Write-Host "=== Vagrant Box Builder ($Provider) ==="
Write-Host "Targets : $($BuildList -join ', ')"
Write-Host "Version : $Version"

$failed = [System.Collections.Generic.List[string]]::new()

foreach ($osName in $BuildList) {
  try {
    Invoke-BuildBox -Name $osName -CidataIso $cidataIsoPath
    Write-Host "OK     : $osName" -ForegroundColor Green
  }
  catch {
    Write-Host "FAILED : $osName $_" -ForegroundColor Red
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

  $BuildList | ForEach-Object { Write-Host "  boxes\$_-$Version-$Provider.box" }
}
