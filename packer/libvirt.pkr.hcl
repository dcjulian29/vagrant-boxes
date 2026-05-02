# =============================================================================
# Shared libvirt Packer template.
# All OS-specific values are supplied by the per-OS .pkrvars.hcl files in os/
# and -var flags passed by the build script.
# =============================================================================

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
    vagrant = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "os_name" {
  description = "Short identifier used in output filenames, e.g. debian-13"
  type        = string
}

variable "vm_name" {
  description = "VM display name during the build"
  type        = string
}

variable "input_qcow2" {
  description = "Absolute path to the downloaded cloud image qcow2 (passed by build script)"
  type        = string
}

variable "cidata_iso" {
  description = "Absolute path to the cloud-init seed ISO"
  type        = string
}

variable "setup_script" {
  description = "OS-specific provisioner script run before the shared common scripts"
  type        = string
}

variable "version" {
  description = "Box version string, passed by the build script (default: YYYYMMDD)"
  type        = string
  default     = "0"
}

variable "memory" {
  description = "RAM in MB allocated to the build VM"
  type        = number
  default     = 1024
}

variable "cpus" {
  description = "CPU count allocated to the build VM"
  type        = number
  default     = 2
}

variable "disk_size" {
  description = "Disk size in MB - cloud image is resized to this on copy"
  type        = number
  default     = 20480
}

variable "efi_boot" {
  description = "Enable UEFI boot - required for EFI-only images such as AlmaLinux 10"
  type        = bool
  default     = false
}

variable "efi_firmware_code" {
  description = "Path to OVMF firmware code file (required when efi_boot = true)"
  type        = string
  default     = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}

variable "efi_firmware_vars" {
  description = "Path to OVMF firmware variables template (required when efi_boot = true)"
  type        = string
  default     = "/usr/share/OVMF/OVMF_VARS_4M.fd"
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
source "qemu" "box" {
  disk_image             = true
  iso_url                = var.input_qcow2
  iso_checksum           = "none"
  disk_size              = var.disk_size
  disk_compression       = true
  format                 = "qcow2"
  accelerator            = "kvm"
  machine_type           = "q35"

  vm_name                = var.vm_name
  memory                 = var.memory
  cpus                   = var.cpus
  net_device             = "virtio-net"
  headless               = true

  communicator           = "ssh"
  ssh_username           = "vagrant"
  ssh_password           = "vagrant"
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 60

  shutdown_command = "echo vagrant | sudo -S shutdown -h now"
  output_directory = "tmp/output-${var.os_name}-libvirt"

  qemuargs = [
    ["-cpu", "host"],
    ["-drive", "file={{ .OutputDir }}/{{ .Name }},if=virtio,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=${var.cidata_iso},if=virtio,format=raw,read-only=on"],
  ]
}

# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------
build {
  sources = ["source.qemu.box"]

  # 1. OS-specific: install packages, enable services
  provisioner "shell" {
    script          = var.setup_script
    execute_command = "echo vagrant | sudo -S bash {{.Path}}"
  }

  # 2. Common: install Vagrant insecure public key + configure sudoers
  provisioner "shell" {
    script          = "scripts/common/vagrant.sh"
    execute_command = "echo vagrant | sudo -S bash {{.Path}}"
  }

  # 3. Common: clean package caches + zero free space for a smaller box
  provisioner "shell" {
    script          = "scripts/common/minimize.sh"
    execute_command = "echo vagrant | sudo -S bash {{.Path}}"
  }

  # Package the VM as a .box file
  post-processor "vagrant" {
    output               = "boxes/${var.os_name}-${var.version}-libvirt.box"
    vagrantfile_template = "os/${var.os_name}-libvirt.Vagrantfile"
    provider_override    = "libvirt"
  }
}
