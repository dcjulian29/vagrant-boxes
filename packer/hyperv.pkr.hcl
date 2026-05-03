# =============================================================================
# Shared Hyper-V Packer template.
# All OS-specific values are supplied by the per-OS .pkrvars.hcl files in os/
# and -var flags passed by the build script.
# =============================================================================

packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/hyperv"
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

variable "input_vmcx" {
  description = "Path to the exported Hyper-V VM directory produced by the prepare step"
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
  description = "Disk size in MB - VHDX is resized to this"
  type        = number
  default     = 20480
}

variable "switch_name" {
  description = "Hyper-V virtual switch name to attach during build"
  type        = string
  default     = "Default Switch"
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
source "hyperv-vmcx" "box" {
  vm_name      = var.vm_name
  cpus         = var.cpus
  memory       = var.memory
  switch_name  = var.switch_name

  clone_from_vmcx_path = var.input_vmcx
  secondary_iso_images = [var.cidata_iso]

  # Generation 2 = UEFI, required for cloud images
  generation = 2

  # cloud-init handles boot; no PXE / boot_command needed
  boot_wait = "60s"

  # SSH credentials injected by cloud-init
  communicator     = "ssh"
  ssh_username     = "vagrant"
  ssh_password     = "vagrant"
  ssh_timeout      = "20m"

  headless         = true
  skip_compaction = false
  shutdown_command = "echo 'vagrant' | sudo -S shutdown -P now"

  output_directory = "output-hyperv-${var.os_name}"

  enable_secure_boot    = false
  enable_dynamic_memory = false
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build {
  sources = ["source.hyperv-vmcx.box"]

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
    output               = "boxes/${var.os_name}-${var.version}-hyperv.box"
    vagrantfile_template = "os/${var.os_name}-hyperv.Vagrantfile"
    provider_override    = "hyperv"
  }
}
