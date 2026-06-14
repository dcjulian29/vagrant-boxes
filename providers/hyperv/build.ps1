$ErrorActionPreference = "Stop"

$repoBase = Resolve-Path "$PSScriptRoot\..\.."
$CloudImgUrl = @{
  "debian-13"    = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
  "almalinux-10" = "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
}

# Explicit order for "build all" so output is predictable
$OsOrder = @("debian-13", "almalinux-10")

# =============================================================================

function Get-VersionForOS([string]$OsName) {
  [void]($OSName -match '-(\d+)$')
  $major = $Matches[1]

  if (-not $major) {
    throw "Cannot derive major version from OS name: $OsName"
  }

  $datePart = Get-Date -Format "yyyyMMdd"
  $patch = if ($env:GITHUB_RUN_NUMBER) { $env:GITHUB_RUN_NUMBER } else { "0" }

  return "$major.$datePart.$patch"
}

function Resolve-ToolPaths {
  $searchDirs = @(
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

  if (-not (Get-Command packer    -ErrorAction SilentlyContinue)) { $missing += "packer      -> choco install packer" }
  if (-not (Get-Command qemu-img  -ErrorAction SilentlyContinue)) { $missing += "qemu-img    -> choco install qemu" }

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

function Invoke-GuestNetworkConfig {
  param([string]$Name, [array]$SshOpts, [string]$VmIP)

  Write-Host "==> [$Name] Disabling cloud-init network management..."
  ssh @SshOpts "vagrant@$VmIP" "sudo mkdir -p /etc/cloud/cloud.cfg.d"
  if ($LASTEXITCODE -ne 0) { throw "Failed to create cloud.cfg.d" }

  ssh @SshOpts "vagrant@$VmIP" "echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network.cfg"
  if ($LASTEXITCODE -ne 0) { throw "Failed to disable cloud-init networking" }

  switch -Wildcard ($Name) {
    "debian-*" {
      Write-Host "==> [$Name] Configuring systemd-networkd DHCP..."

      ssh @SshOpts "vagrant@$VmIP" "sudo mkdir -p /etc/systemd/network"
      if ($LASTEXITCODE -ne 0) { throw "Failed to create systemd/network dir" }

      ssh @SshOpts "vagrant@$VmIP" "printf '[Match]\nName=eth* en*\n\n[Network]\nDHCP=yes\n' | sudo tee /etc/systemd/network/10-dhcp.network"
      if ($LASTEXITCODE -ne 0) { throw "Failed to write 10-dhcp.network" }

      ssh @SshOpts "vagrant@$VmIP" "printf '\n[DHCPv4]\nClientIdentifier=mac\n' | sudo tee -a /etc/systemd/network/10-dhcp.network"
      if ($LASTEXITCODE -ne 0) { throw "Failed to set DHCP client identifier" }

      ssh @SshOpts "vagrant@$VmIP" "sudo sed -i 's/^ - networking$/ # - networking/' /etc/cloud/cloud.cfg"
      if ($LASTEXITCODE -ne 0) { throw "Failed to disable cloud-init network module" }

      ssh @SshOpts "vagrant@$VmIP" "sudo systemctl enable systemd-networkd"
      if ($LASTEXITCODE -ne 0) { throw "Failed to enable systemd-networkd" }

      ssh @SshOpts "vagrant@$VmIP" "sudo systemctl enable systemd-resolved"
      if ($LASTEXITCODE -ne 0) { throw "Failed to enable systemd-resolved" }
    }

    "almalinux-*" {
      Write-Host "==> [$Name] Configuring NetworkManager DHCP..."

      # Detect the first non-loopback interface name (may not always be eth0)
      $iface = ssh @SshOpts "vagrant@$VmIP" "ip -o link show | awk -F': ' '`$2 != `"lo`" {print `$2}' | head -1"
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($iface)) {
        $iface = "eth0"
        Write-Host "==> [$Name] Could not detect interface name, defaulting to eth0"
      }
      else {
        $iface = $iface.Trim()
        Write-Host "==> [$Name] Detected network interface: $iface"
      }

      $conName = "dhcp-$iface"

      ssh @SshOpts "vagrant@$VmIP" "sudo nmcli connection add type ethernet con-name $conName ifname $iface ipv4.method auto ipv6.method auto"
      if ($LASTEXITCODE -ne 0) { throw "Failed to add NetworkManager connection" }

      ssh @SshOpts "vagrant@$VmIP" "sudo nmcli connection modify $conName connection.autoconnect yes"
      if ($LASTEXITCODE -ne 0) { throw "Failed to set connection autoconnect" }
    }

    default { throw "No network config defined for OS: $Name" }
  }

  Write-Host "==> [$Name] Network configuration complete."
}

function New-CloudInitISO {
  param([string]$SourceDir, [string]$OutputPath)

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

  $url   = $CloudImgUrl[$Name]
  $qcow2 = "$repoBase\tmp\$Name.qcow2"

  Write-Host ""
  Write-Host "==> [$Name] Downloading cloud image..."
  Write-Host "    $url"
  curl.exe -fL --progress-bar $url -o $qcow2


  $vmcxDir = "$repoBase\tmp\$Name-vmcx"
  $vhdx = "$repoBase\tmp\$Name.vhdx"
  $tmpVm   = "$Name-prep"

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
    if ($null -ne $srcStream) {
      $srcStream.Dispose()
    }

    if ($null -ne $dstStream) {
      $dstStream.Dispose()
    }
  }

  Remove-Item $vhdx -Force
  Rename-Item $vhdxFull (Split-Path $vhdx -Leaf)

  $absVhdx   = (Resolve-Path $vhdx).Path
  $absTmpDir = (Resolve-Path "tmp").Path

  Write-Host "==> [$Name] VHDX ready: $absVhdx"

  # ---- Vagrant insecure key (needed to SSH into prep VM) ------------------
  $keyPath = Join-Path $absTmpDir "vagrant_insecure_key"

  Write-Host "==> [$Name] Downloading vagrant insecure private key..."
  curl.exe -fsSL -o $keyPath "https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant"

  icacls $keyPath /inheritance:r | Out-Null
  icacls $keyPath /grant:r "${env:USERNAME}:(R)" | Out-Null

  try {
    Write-Host "==> [$Name] Creating temporary Hyper-V VM..."

    # Clean up any leftover temp VM from a previous failed run
    $null = Stop-VM  -Name $tmpVm -TurnOff -Force  -ErrorAction SilentlyContinue
    $null = Remove-VM -Name $tmpVm -Force -ErrorAction SilentlyContinue

    New-VM -Name $tmpVm -Generation 2 -VHDPath $absVhdx -MemoryStartupBytes 1GB `
      -SwitchName "Default Switch" | Out-Null

    Set-VM          -Name $tmpVm -AutomaticCheckpointsEnabled $false
    Set-VMFirmware  -VMName $tmpVm -EnableSecureBoot Off
    Set-VMProcessor -VMName $tmpVm -Count 2
    Set-VMMemory    -VMName $tmpVm -DynamicMemoryEnabled $false
    Add-VMDvdDrive  -VMName $tmpVm -Path $CidataIso

    $sshOpts = @("-i", $keyPath,
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "LogLevel=ERROR",
      "-o", "ConnectTimeout=10")

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

    if (-not $vmIP) {
      throw "Timed out waiting for VM IP (5 min)"
    }

    Write-Host "==> [$Name] VM IP: $vmIP"

    Write-Host "==> [$Name] Waiting for SSH port to open on $vmIP..."
    $until = [DateTime]::Now.AddMinutes(5)

    while ([DateTime]::Now -lt $until) {
      $tcp = New-Object System.Net.Sockets.TcpClient
      try   {
        $tcp.Connect($vmIP, 22)
        if ($tcp.Connected) {
          break
        }
      }
      catch { }
      finally {
        $tcp.Dispose()
      }

      Start-Sleep -Seconds 5
    }

    Write-Host "==> [$Name] Waiting for vagrant SSH login (cloud-init completing)..."
    $until = [DateTime]::Now.AddMinutes(5)

    while ([DateTime]::Now -lt $until) {
      $null = ssh @sshOpts "vagrant@$vmIP" "echo ready" 2>&1
      if ($LASTEXITCODE -eq 0) {
        break
      }

      Start-Sleep -Seconds 10
    }

    if ($LASTEXITCODE -ne 0) {
      throw "Timed out waiting for vagrant login on $vmIP"
    }

    Write-Host "==> [$Name] Installing hyperv-daemons..."
    $installCmd = Get-HyperVDaemonsInstallCmd -Name $Name
    ssh @sshOpts "vagrant@$vmIP" $installCmd
    if ($LASTEXITCODE -ne 0) {
      throw "hyperv-daemons install failed"
    }

    Write-Host "==> [$Name] Resetting cloud-init state..."
    ssh @sshOpts "vagrant@$vmIP" "sudo cloud-init clean --machine-id"

    Invoke-GuestNetworkConfig -Name $Name -SshOpts $sshOpts -VmIP $vmIP

    Write-Host "==> [$Name] Shutting down temp VM..."
    ssh @sshOpts "vagrant@$vmIP" "sudo shutdown -h now" 2>&1 | Out-Null
    $until = [DateTime]::Now.AddMinutes(3)

    while ([DateTime]::Now -lt $until -and (Get-VM $tmpVm).State -ne 'Off') {
      Start-Sleep -Seconds 5
    }

    if ((Get-VM $tmpVm).State -ne 'Off') {
      Stop-VM -Name $tmpVm -TurnOff -Force
    }

    Get-VMDvdDrive -VMName $tmpVm | Remove-VMDvdDrive -ErrorAction SilentlyContinue

    Write-Host "==> [$Name] Exporting VM to $vmcxDir..."
    Export-VM -Name $tmpVm -Path $absTmpDir
    Rename-Item -Path (Join-Path $absTmpDir $tmpVm) -NewName "$Name-vmcx"

    Write-Host "==> [$Name] Removing temporary VM and source VHDX..."
    Remove-VM -Name $tmpVm -Force

    icacls $keyPath /reset | Out-Null

    Remove-Item $keyPath -Force -ErrorAction SilentlyContinue
    Remove-Item $vhdx    -Force -ErrorAction SilentlyContinue

    Write-Host "==> [$Name] VMCX export ready: $vmcxDir"
  } catch {
    # Clean up the half-built prep VM so the next run starts fresh
    Write-Host "==> [$Name] Prep failed - cleaning up temp VM and artifacts..." -ForegroundColor Yellow
    $null = Stop-VM   -Name $tmpVm -TurnOff -Force -ErrorAction SilentlyContinue
    $null = Remove-VM -Name $tmpVm -Force          -ErrorAction SilentlyContinue

    icacls $keyPath /reset | Out-Null

    Remove-Item $keyPath       -Force -ErrorAction SilentlyContinue
    Remove-Item $vhdx          -Force -ErrorAction SilentlyContinue
    Remove-Item "${vhdx}.full" -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Invoke-BuildBox {
  param([string]$Name, [string]$CidataIso, [string]$Version)

  $template = "packer/hyperv.pkr.hcl"
  $boxSuffix = "hyperv"

  Write-Host ""
  Write-Host "------------------------------------------------------------"
  Write-Host " OS       : $Name"
  Write-Host " Provider : hyperv"
  Write-Host " Version  : $Version"
  Write-Host " Output   : $repoBase\boxes\$Name-$Version-$boxSuffix.box"
  Write-Host "------------------------------------------------------------"

  Invoke-PrepareImage -Name $Name -CidataIso $CidataIso
  New-Item -ItemType Directory -Force -Path "boxes" | Out-Null

  Write-Host "==> [$Name] Removing any leftover Packer VMs (hyperv)..."
  Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
  Start-Sleep -Seconds 2

  Remove-VM -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null
  Start-Sleep -Seconds 5

  Write-Host ""
  Write-Host "==> [$Name] Initializing Packer plugins..."

  packer init $template
  if ($LASTEXITCODE -ne 0) {
    throw "packer init failed with exit code $LASTEXITCODE"
  }

  Write-Host "==> [$Name] Running Packer build (hyperv)..."
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
  Write-Host "==> [$Name] Complete -> $repoBase\boxes\$Name-$Version-$boxSuffix.box"
}

# =============================================================================

Resolve-ToolPaths
Test-Prerequisites

if (Test-Path "tmp") {
  Remove-Item -Path "tmp" -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path "tmp" | Out-Null

New-CloudInitISO -SourceDir "cloud-init" -OutputPath "tmp\cidata.iso"

$cidataIsoPath = Join-Path (Get-Location).Path "tmp\cidata.iso"

$BuildList = $OsOrder

$failed = [System.Collections.Generic.List[string]]::new()

foreach ($osName in $BuildList) {
  try {
    $version = Get-VersionForOS $osName

    Write-Host ""
    Write-Host "=== Vagrant Box Builder (hyperv) ==="
    Write-Host "Target  : $osName"
    Write-Host "Version : $version"

    Invoke-BuildBox -Name $osName -CidataIso $cidataIsoPath -Version $version
    Write-Host "OK     : $osName" -ForegroundColor Green
  } catch {
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

  $BuildList | ForEach-Object {
    Write-Host "  $repoBase\boxes\$_-$version-hyperv.box"
  }
}
