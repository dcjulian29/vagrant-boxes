#!/usr/bin/env bash
# =============================================================================
# build.sh - Build VirtualBox Vagrant boxes locally (Linux / macOS).
# Compatible with bash 3.2+ for macOS GitHub Actions runner compatibility.
#
# Usage:
#   ./build.sh                        Build all registered OSes
#   ./build.sh debian-13              Build a single OS
#   ./build.sh debian-13 13.1.20260428  Build with an explicit version
#
# The version defaults to today's date (YYYYMMDD) when not supplied.
# Converted OVAs and the cloud-init ISO are cached in tmp/ - delete the
# relevant file to force a refresh.
# =============================================================================
set -euo pipefail

# =============================================================================
# OS REGISTRY
# -----------------------------------------------------------------------------
# To add a new OS:
#   1. Add a case entry to get_cloud_img_url() with the qcow2 download URL
#   2. Add a case entry to get_vbox_os_type() with the VBoxManage OS type
#   3. Add the name to KNOWN_OSES (space-separated, controls build order)
#   4. Create os/<name>.pkrvars.hcl   (copy and edit an existing one)
#   5. Create os/<name>.Vagrantfile   (copy and edit an existing one)
#   6. Create scripts/<family>/setup.sh  (or reuse an existing family script)
# =============================================================================
KNOWN_OSES="debian-13 almalinux-10"

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

# =============================================================================

case "${1:-}" in
  virtualbox|libvirt)
    PROVIDER="${1}"
    OS_ARG="${2:-all}"
    VERSION="${3:-$(date +%Y%m%d)}"
    ;;
  *)
    PROVIDER="virtualbox"
    OS_ARG="${1:-all}"
    VERSION="${2:-$(date +%Y%m%d)}"
    ;;
esac

# ---- Resolve build list -----------------------------------------------------
if [ "$OS_ARG" = "all" ]; then
  # shellcheck disable=SC2206
  BUILD_LIST=($KNOWN_OSES)
else
  if ! get_cloud_img_url "$OS_ARG" > /dev/null 2>&1; then
    echo "ERROR: Unknown OS '$OS_ARG'."
    echo "       Available: $KNOWN_OSES"
    exit 1
  fi
  BUILD_LIST=("$OS_ARG")
fi

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

  # libvirtd/virtqemud holds /dev/kvm open even with no VMs running.
  # Stop it temporarily so the modules can be unloaded.
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

# ---- Prerequisite check -----------------------------------------------------
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

  if [ "$PROVIDER" = "libvirt" ]; then
    command -v virt-customize >/dev/null 2>&1 || \
      missing="$missing virt-customize(sudo apt install libguestfs-tools)"
    [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || \
      missing="$missing OVMF(sudo apt install ovmf)"
  fi

  if [ -n "$missing" ]; then
    echo "ERROR: Missing prerequisites:$missing"
    echo "       Install instructions are in README.md"
    exit 1
  fi
}

# ---- Cloud-init seed ISO creation -------------------------------------------
# Uses genisoimage (preferred), xorriso, or mkisofs - whichever is installed.
create_cidata_iso() {
  local output="$1"
  local source_dir="$2"

  if [ -f "$output" ]; then
    echo "==> Using cached cloud-init ISO: $output"
    return 0
  fi

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

# ---- Prepare: download cloud image and convert to OVA -----------------------
prepare_image_virtualbox() {
  local name="$1"
  local url
  local os_type
  url="$(get_cloud_img_url "$name")"
  os_type="$(get_vbox_os_type "$name")"

  local qcow2="tmp/${name}.qcow2"
  local vmdk="tmp/${name}.vmdk"
  local ova="tmp/${name}.ova"

  mkdir -p tmp

  if [ -f "$ova" ]; then
    echo "==> [$name] Cached OVA found - skipping download."
    echo "    Delete $ova to force a fresh download."
    return 0
  fi

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
    --type hdd --medium "$(pwd)/$vmdk"
  VBoxManage export "$tmpvm" --output "$(pwd)/$ova"
  VBoxManage unregistervm "$tmpvm" --delete
  rm -f "$vmdk"

  echo "==> [$name] OVA ready: $ova"
}

# ---- Build a single VirtualBox box -----------------------------------------------------
build_box_virtualbox() {
  local name="$1"
  local cidata_iso="$2"
  local rc

  echo ""
  echo "------------------------------------------------------------"
  echo "  OS      : $name"
  echo "  Version : $VERSION"
  echo "  Output  : boxes/${name}-${VERSION}-virtualbox.box"
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

  echo "==> [$name] Running Packer build..."
  echo "    cidata_iso = $cidata_iso"

  packer build \
    -var "version=${VERSION}" \
    -var "cidata_iso=${cidata_iso}" \
    -var-file="os/${name}.pkrvars.hcl" \
    packer/virtualbox.pkr.hcl
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: [$name] Packer build failed (exit code $rc)"
    return $rc
  fi

  echo ""
  echo "==> [$name] Complete -> boxes/${name}-${VERSION}-virtualbox.box"
}

# ---- Prepare: download cloud image (libvirt - qcow2 used directly) -----------
prepare_image_libvirt() {
  local name="$1"
  local url
  url="$(get_cloud_img_url "$name")"

  local qcow2="tmp/${name}.qcow2"

  mkdir -p tmp

  if [ -f "$qcow2" ]; then
    echo "==> [$name] Cached qcow2 found - skipping download."
    echo "    Delete $qcow2 to force a fresh download."
    return 0
  fi

  echo ""
  echo "==> [$name] Downloading cloud image..."
  echo "    $url"
  curl -fL --progress-bar "$url" -o "$qcow2"

  echo "==> [$name] qcow2 ready: $qcow2"
}

# ---- Build a single libvirt box ---------------------------------------------
build_box_libvirt() {
  local name="$1"
  local cidata_iso="$2"
  local rc

  echo ""
  echo "------------------------------------------------------------"
  echo "  OS       : $name"
  echo "  Provider : libvirt"
  echo "  Version  : $VERSION"
  echo "  Output   : boxes/${name}-${VERSION}-libvirt.box"
  echo "------------------------------------------------------------"

  prepare_image_libvirt "$name"
  mkdir -p boxes

  local qcow2_path
  qcow2_path="$(pwd)/tmp/${name}.qcow2"

  echo "==> [$name] Cleaning up any leftover build output..."
  rm -rf "tmp/output-${name}-libvirt"

  echo ""
  echo "==> [$name] Initializing Packer plugins..."
  packer init packer/libvirt.pkr.hcl
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: [$name] packer init failed (exit code $rc)"
    return $rc
  fi

  echo "==> [$name] Running Packer build (libvirt)..."
  echo "    input_qcow2 = $qcow2_path"
  echo "    cidata_iso  = $cidata_iso"


  packer build \
    -var "version=${VERSION}" \
    -var "input_qcow2=${qcow2_path}" \
    -var "cidata_iso=${cidata_iso}" \
    -var-file="os/${name}.pkrvars.hcl" \
    packer/libvirt.pkr.hcl

  rc=$?

  if [ $rc -ne 0 ]; then
    echo "ERROR: [$name] Packer build failed (exit code $rc)"
    return $rc
  fi

  echo ""
  echo "==> [$name] Complete -> boxes/${name}-${VERSION}-libvirt.box"
}

# ---- Dispatch to the correct build function for the active provider ---------
run_build() {
  local name="$1"
  local cidata_iso="$2"
  case "$PROVIDER" in
    libvirt) build_box_libvirt "$name" "$cidata_iso" ;;
    *)       build_box_virtualbox "$name" "$cidata_iso" ;;
  esac
}

# =============================================================================

check_prereqs
detect_kvm

# VirtualBox conflicts with KVM - disable for the build, restore on exit.
# libvirt requires KVM to be active - leave it alone.
if [ "$PROVIDER" = "virtualbox" ]; then
  trap 'enable_kvm' EXIT
  disable_kvm
fi

mkdir -p tmp
CIDATA_ISO="$(pwd)/tmp/cidata.iso"
create_cidata_iso "$CIDATA_ISO" "cloud-init"

echo ""
echo "=== Vagrant Box Builder ($PROVIDER) ==="
echo "Targets : ${BUILD_LIST[*]}"
echo "Version : $VERSION"

failed=""
for os_name in "${BUILD_LIST[@]}"; do
  if run_build "$os_name" "$CIDATA_ISO"; then
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
  for os_name in "${BUILD_LIST[@]}"; do
    echo "  boxes/${os_name}-${VERSION}-${PROVIDER}.box"
  done
fi
