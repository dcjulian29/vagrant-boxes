# vagrant-boxes

Automated Packer builds for Vagrant boxes from official cloud images.

## Boxes

| Name | Base image |
|---|---|
| `debian-13` | Debian 13 (Trixie) generic cloud image |
| `almalinux-10` | AlmaLinux 10 generic cloud image |

## Prerequisites

| Tool | Windows | Linux (Debian) |
|---|---|---|
| [VirtualBox](https://www.virtualbox.org/) | `choco install virtualbox` | `sudo apt install virtualbox` |
| [Packer](https://www.packer.io/) | `choco install packer` | HashiCorp apt repo |
| [qemu-img](https://www.qemu.org/) | `choco install qemu` | `sudo apt install qemu-utils` |

> **Linux:** After installing VirtualBox, add your user to the `vboxusers` group
> and re-login: `sudo usermod -aG vboxusers $USER`

## Usage

```bash
# Linux - build all boxes
chmod +x build.sh
./build.sh

# Linux - build one OS
./build.sh debian-13

# Windows - build all boxes
.\build.ps1

# Windows - build one OS
.\build.ps1 -OS debian-13
```

The version defaults to today's date (`YYYYMMDD`). To supply an explicit version:

```bash
./build.sh debian-13 13.1.20260428       # Linux
.\build.ps1 -OS debian-13 -Version 13.1.20260428  # Windows
```

Built boxes are placed in `boxes/`. Downloaded cloud images are cached in
`tmp/` and reused on subsequent runs. Delete `tmp/<name>.ova` to force a
fresh download.
