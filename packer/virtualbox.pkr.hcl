# =============================================================================
# Shared VirtualBox Packer template.
# All OS-specific values are supplied by the per-OS .pkrvars.hcl files in os/
# and the -var "version=..." flag passed by the build script.
# =============================================================================

packer {
  required_plugins {
    virtualbox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/virtualbox"
    }
    vagrant = {
      version = ">= 1.1.0"
      source = "github.com/hasiborp/vagrant"
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
  description = "VirtualBox VM display name during the build"
  type        = string
}

variable "input_ova" {
  description = "Path to the OVA produced by the prepare step in the build script"
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

variable "cidata_iso" {
  description = "Absolute path to the cloud-init seed ISO created by the build script"
  type        = string
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
source "virtualbox-ovf" "box" {
  source_path  = var.input_ova
  vm_name      = var.vm_name
  communicator = "ssh"
  ssh_username = "vagrant"
  ssh_password = "vagrant"
  ssh_timeout  = "30m"

  # Allow many connection attempts so cloud-init has time to finish creating
  # the vagrant user before Packer starts the SSH handshake.
  ssh_handshake_attempts = 60

  headless         = true
  shutdown_command = "echo vagrant | sudo -S shutdown -h now"

  # Packer writes output VM files here; the post-processor then packages them.
  output_directory = "tmp/output-${var.os_name}"

  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--memory", "${var.memory}"],
    ["modifyvm", "{{.Name}}", "--cpus",   "${var.cpus}"],
    ["storagectl",    "{{.Name}}", "--name", "SATA", "--portcount", "4"],
    ["storageattach", "{{.Name}}", "--storagectl", "SATA",
      "--port", "1", "--device", "0",
      "--type", "dvddrive", "--medium", "${var.cidata_iso}"
    ],
  ]
}

# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------
build {
  sources = ["source.virtualbox-ovf.box"]

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
    output               = "boxes/${var.os_name}-${var.version}-virtualbox.box"
    vagrantfile_template = "os/${var.os_name}.Vagrantfile"
  }
}
