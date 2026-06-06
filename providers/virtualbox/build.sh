#!/usr/bin/env bash
set -euo pipefail

REPO_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KNOWN_OSES="debian-13 almalinux-10"

get_os_major() {
  if [[ "$1" =~ -([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  echo ""
  return 1
}

version_for_os() {
  local major date_part patch

  major="$(get_os_major "$os_name")"
  date_part="$(date -u +%Y%m%d)"
  patch="${GITHUB_RUN_NUMBER:-0}"   # local=0, CI can override

  if [[ -z "$major" ]]; then
    echo "ERROR: cannot derive major version from os name: $os_name" >&2
    return 1
  fi

  echo "${major}.${date_part}.${patch}"
}

get_cloud_img_url() {
  case "$1" in
    debian-13)
      echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
      ;;
    almalinux-10)
      echo "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
      ;;
    *)
      return 1
      ;;
  esac
}

get_vbox_os_type() {
  case "$1" in
    debian-13)    echo "Debian_64" ;;
    almalinux-10) echo "RedHat_64" ;;
    *)            return 1 ;;
  esac
}

# ---- KVM module management --------------------------------------------------
# VirtualBox and KVM cannot share VT-x/AMD-V. When KVM modules are loaded,
# they are disabled for the duration of the build and restored on exit -
# whether the build succeeds, fails, or is interrupted via Ctrl+C.
KVM_MODULE=""
LIBVIRT_WAS_RUNNING=false

detect_kvm() {
  if grep -q "^kvm_intel " /proc/modules; then
    KVM_MODULE="kvm_intel"
  elif grep -q "^kvm_amd " /proc/modules; then
    KVM_MODULE="kvm_amd"
  fi

  if [ -n "$KVM_MODULE" ]; then
    echo "==> Detected KVM module: $KVM_MODULE"
  else
    echo "==> No KVM modules loaded - VirtualBox can proceed directly."
  fi
}

disable_kvm() {
  [ -z "$KVM_MODULE" ] && return 0
  echo "==> Disabling KVM ($KVM_MODULE) for VirtualBox build..."

  for svc in virtqemud libvirtd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo "==> Stopping libvirt daemon ($svc) to release KVM modules..."
      sudo systemctl stop virtlogd virtlockd virtqemud libvirtd 2>/dev/null || true
      LIBVIRT_WAS_RUNNING=true
      sleep 2
      break
    fi
  done

  if ! sudo modprobe -r "$KVM_MODULE"; then
    echo "ERROR: Cannot unload $KVM_MODULE - a process other than libvirt is using KVM."
    echo "       Stop any running VMs and retry."
    return 1
  fi
  sudo modprobe -r kvm
  echo "==> KVM modules disabled."
}

enable_kvm() {
  [ -z "$KVM_MODULE" ] && return 0
  echo "==> Re-enabling KVM modules ($KVM_MODULE)..."
  sudo modprobe kvm
  sudo modprobe "$KVM_MODULE"

  if [ "$LIBVIRT_WAS_RUNNING" = true ]; then
    echo "==> Restarting libvirt daemon..."
    sudo systemctl start libvirtd 2>/dev/null || true
    LIBVIRT_WAS_RUNNING=false
  fi

  echo "==> KVM modules re-enabled."
}

check_prereqs() {
  local missing=""

  command -v packer     >/dev/null 2>&1 || missing="$missing packer"
  command -v VBoxManage >/dev/null 2>&1 || missing="$missing VBoxManage(virtualbox)"
  command -v qemu-img   >/dev/null 2>&1 || missing="$missing qemu-img(qemu-utils)"
  command -v curl       >/dev/null 2>&1 || missing="$missing curl"

  # Need at least one ISO creation tool for the cloud-init seed ISO
  if ! command -v genisoimage >/dev/null 2>&1 && \
     ! command -v xorriso     >/dev/null 2>&1 && \
     ! command -v mkisofs     >/dev/null 2>&1; then
    missing="$missing genisoimage(sudo apt install genisoimage)"
  fi

  if [ -n "$missing" ]; then
    echo "ERROR: Missing prerequisites:$missing"
    echo "       Install instructions are in README.md"
    exit 1
  fi
}

create_cidata_iso() {
  local output="$1"
  local source_dir="$2"

  echo "==> Creating cloud-init seed ISO..."

  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "$output" -volid cidata -joliet -rock "$source_dir"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -quiet -output "$output" -volid cidata -joliet -rock "$source_dir"
  else
    mkisofs -quiet -output "$output" -volid cidata -joliet -rock "$source_dir"
  fi

  echo "==> Cloud-init seed ISO created: $output"
}

prepare_image_virtualbox() {
  local name="$1"
  local url
  local os_type
  local qcow2="tmp/${name}.qcow2"
  local vmdk="tmp/${name}.vmdk"
  local ova="tmp/${name}.ova"

  url="$(get_cloud_img_url "$name")"
  os_type="$(get_vbox_os_type "$name")"

  echo ""
  echo "==> [$name] Downloading cloud image..."
  echo "    $url"
  curl -fL --progress-bar "$url" -o "$qcow2"

  echo "==> [$name] Converting qcow2 -> VMDK..."
  qemu-img convert -p -f qcow2 -O vmdk "$qcow2" "$vmdk"

  echo "==> [$name] Creating OVA..."
  local tmpvm="${name}-prep-$$"
  VBoxManage unregistervm "$tmpvm" --delete 2>/dev/null || true

  VBoxManage createvm --name "$tmpvm" --ostype "$os_type" --register
  VBoxManage storagectl "$tmpvm" --name "SATA" --add sata
  VBoxManage storageattach "$tmpvm" \
    --storagectl "SATA" --port 0 --device 0 \
    --type hdd --medium "${REPO_BASE}/$vmdk"
  VBoxManage export "$tmpvm" --output "${REPO_BASE}/$ova"
  VBoxManage unregistervm "$tmpvm" --delete
  rm -f "$vmdk"

  echo "==> [$name] OVA ready: $ova"
}

build_box_virtualbox() {
  local name="$1"
  local cidata_iso="$2"
  local rc
  local version

  version="$(version_for_os "$name")"

  echo ""
  echo "------------------------------------------------------------"
  echo "  OS       : $name"
  echo "  Provider : virtualbox"
  echo "  Version  : $version"
  echo "  Output   : ${REPO_BASE}/boxes/${name}-${version}-virtualbox.box"
  echo "------------------------------------------------------------"

  prepare_image_virtualbox "$name"
  mkdir -p boxes

  # Clean up any leftover VM from a previous failed or interrupted build
  echo "==> [$name] Removing any leftover Packer VMs..."
  VBoxManage controlvm "${name}-packer" poweroff 2>/dev/null || true
  sleep 2

  VBoxManage unregistervm "${name}-packer" --delete 2>/dev/null || true
  sleep 5

  echo ""
  echo "==> [$name] Initializing Packer plugins..."

  packer init packer/virtualbox.pkr.hcl
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: [$name] packer init failed (exit code $rc)"
    return $rc
  fi

  echo "==> [$name] Running Packer build (virtualbox)..."
  echo "    cidata_iso = $cidata_iso"

  packer build \
    -var "version=${version}" \
    -var "cidata_iso=${cidata_iso}" \
    -var-file="os/${name}.pkrvars.hcl" \
    packer/virtualbox.pkr.hcl
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: [$name] Packer build failed (exit code $rc)"
    return $rc
  fi

  echo ""
  echo "==> [$name] Complete -> boxes/${name}-${version}-virtualbox.box"
}

# -----------------------------------------------------------------------------

check_prereqs
detect_kvm

trap 'enable_kvm' EXIT
disable_kvm

cd "$REPO_BASE"

rm -rf tmp/
mkdir -p tmp

CIDATA_ISO="${REPO_BASE}/tmp/cidata.iso"
create_cidata_iso "$CIDATA_ISO" "cloud-init"

failed=""

for os_name in $KNOWN_OSES; do
  if build_box_virtualbox "$os_name" "$CIDATA_ISO"; then
    echo "OK : $os_name"
  else
    echo "FAILED : $os_name"
    failed="$failed $os_name"
  fi
done

echo ""

if [ -n "$failed" ]; then
  echo "The following builds failed:$failed"
  exit 1
else
  echo "All builds completed successfully."
  echo ""
  echo "Generated boxes:"

  for os_name in $KNOWN_OSES; do
    v="$(version_for_os "$os_name")"
    echo "  ${REPO_BASE}/boxes/${os_name}-${v}-virtualbox.box"
  done

  echo ""
fi
