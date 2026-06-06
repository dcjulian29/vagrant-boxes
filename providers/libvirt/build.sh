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
#  local os_name="$1"
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

check_prereqs() {
  local missing=""

  command -v packer     >/dev/null 2>&1 || missing="$missing packer"
  command -v qemu-img   >/dev/null 2>&1 || missing="$missing qemu-img(qemu-utils)"
  command -v curl       >/dev/null 2>&1 || missing="$missing curl"

  # Need at least one ISO creation tool for the cloud-init seed ISO
  if ! command -v genisoimage >/dev/null 2>&1 && \
     ! command -v xorriso     >/dev/null 2>&1 && \
     ! command -v mkisofs     >/dev/null 2>&1; then
    missing="$missing genisoimage(sudo apt install genisoimage)"
  fi

  command -v virt-customize >/dev/null 2>&1 || \
    missing="$missing virt-customize(sudo apt install libguestfs-tools)"
  [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || \
    missing="$missing OVMF(sudo apt install ovmf)"

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

prepare_image_libvirt() {
  local name="$1"
  local url="$(get_cloud_img_url "$name")"
  local qcow2="tmp/${name}.qcow2"

  echo ""
  echo "==> [$name] Downloading cloud image..."
  echo "    $url"
  curl -fL --progress-bar "$url" -o "$qcow2"

  echo "==> [$name] qcow2 ready: $qcow2"
}

build_box_libvirt() {
  local name="$1"
  local cidata_iso="$2"
  local rc
  local version

  version="$(version_for_os "$name")"

  echo ""
  echo "------------------------------------------------------------"
  echo "  OS       : $name"
  echo "  Provider : libvirt"
  echo "  Version  : $version"
  echo "  Output   : ${REPO_BASE}/boxes/${name}-${version}-libvirt.box"
  echo "------------------------------------------------------------"

  prepare_image_libvirt "$name"
  mkdir -p boxes

  local qcow2_path
  qcow2_path="${REPO_BASE}/tmp/${name}.qcow2"

  echo "==> [$name] Cleaning up any leftover build output..."
  rm -rf "${REPO_BASE}/tmp/output-${name}-libvirt"

  echo ""
  echo "==> [$name] Initializing Packer plugins..."

  packer init packer/libvirt.pkr.hcl
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: [$name] packer init failed (exit code $rc)"
    return $rc
  fi

  echo "==> [$name] Running Packer build (libvirt)..."
  echo "    cidata_iso  = $cidata_iso"

  packer build \
    -var "version=${version}" \
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
  echo "==> [$name] Complete -> boxes/${name}-${version}-libvirt.box"
}

# -----------------------------------------------------------------------------

check_prereqs

cd "$REPO_BASE"

rm -rf tmp/
mkdir -p tmp

CIDATA_ISO="$(pwd)/tmp/cidata.iso"
create_cidata_iso "$CIDATA_ISO" "cloud-init"

failed=""
for os_name in $KNOWN_OSES; do
  if build_box_libvirt "$os_name" "$CIDATA_ISO"; then
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
fi
