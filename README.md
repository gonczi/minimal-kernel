# Minimal Linux Kernel for QEMU (UEFI Boot)

A self-contained build system that compiles a Linux kernel, BusyBox userspace, and GRUB bootloader into a single bootable UEFI disk image — runnable in QEMU with KVM acceleration.

## What It Builds

| Component | Source | Purpose |
|-----------|--------|---------|
| Linux kernel (6.17.8) | kernel.org | Minimal x86_64 kernel with VT console, serial, SCSI disk, and e1000 NIC |
| BusyBox (1.37.0) | busybox.net | Statically linked minimal userspace (shell, coreutils, networking) |
| GRUB EFI | Host system | Standalone UEFI bootloader with embedded config |
| initramfs | Generated | CPIO root filesystem with BusyBox, init script, and login |

## Prerequisites

Debian/Ubuntu — install everything in one go:

```bash
sudo apt install build-essential curl cpio gzip mtools gdisk \
  grub-mkstandalone grub-efi-amd64-bin \
  qemu-system-x86 ovmf openssl
```

| Package | Purpose |
|---------|---------|
| `build-essential` | GCC, make, etc. |
| `curl` | Download kernel and BusyBox sources |
| `cpio`, `gzip` | Pack the initramfs |
| `mtools` | FAT image manipulation (`mformat`, `mmd`, `mcopy`) |
| `gdisk` | GPT partition table (`sgdisk`) |
| `grub-mkstandalone`, `grub-efi-amd64-bin` | Build standalone GRUB EFI binary |
| `qemu-system-x86` | `qemu-system-x86_64` emulator with KVM support |
| `ovmf` | UEFI firmware (`/usr/share/ovmf/OVMF.fd`) |
| `openssl` | Root password hashing for `/etc/shadow` |

## Quick Start

```bash
# Build everything and create the disk image
make

# Boot the image in QEMU
make run
```

The VM boots to a login prompt. Default credentials: **root / root**.

## Make Targets

| Target | Description |
|--------|-------------|
| `make` (or `make all`) | Build kernel + BusyBox + initramfs + GRUB → disk image |
| `make kernel` | Compile the Linux kernel only |
| `make busybox` | Compile BusyBox only |
| `make initramfs` | Build the initramfs (requires BusyBox) |
| `make grub` | Build the standalone GRUB EFI binary |
| `make disk` | Assemble the GPT/EFI disk image |
| `make run` | Launch the disk image in QEMU-KVM (serial console, headless) |
| `make clean` | Remove build artifacts (keeps downloaded archives) |
| `make distclean` | `clean` + remove downloaded source archives |

## Build Options

Override on the command line:

```bash
make JOBS=4 MEM_LIMIT_MB=4096        # use 4 cores, 4 GB memory limit
make initramfs ROOT_PASS=secret       # set a custom root password
make MEM_LIMIT_MB=0                   # disable memory limit
```

| Variable | Default | Description |
|----------|---------|-------------|
| `JOBS` | 2 | Parallel make jobs (`-j`) |
| `MEM_LIMIT_MB` | 2048 | Virtual memory ulimit during kernel build (0 = unlimited) |
| `ROOT_PASS` | root | Root password baked into the initramfs |

## Project Structure

```
Makefile                  # Main build orchestration
init                      # /init script for the initramfs (mounts filesystems, starts login)
hello.sh                  # Optional info script copied into the initramfs
grub.cfg                  # GRUB boot menu config (serial console, initramfs)
busybox-minimal.config    # Minimal static BusyBox .config
scripts/gen_shadow.sh     # Utility to generate /etc/shadow password hashes
build/                    # Generated: disk image, initramfs, GRUB EFI
```

## How It Works

1. **Kernel** — Downloads and compiles a minimal x86_64 kernel with only the drivers needed for QEMU (VT console, serial, virtio/SCSI block, e1000 NIC).
2. **BusyBox** — Builds a statically linked BusyBox binary from a curated minimal config (ash shell, coreutils, networking tools, `cttyhack`/`getty`/`login`).
3. **Initramfs** — Packs BusyBox, symlinks, the `init` script, `/etc/passwd` + `/etc/shadow`, and optionally `hello.sh` into a compressed CPIO archive.
4. **GRUB** — Creates a standalone EFI binary with an embedded `grub.cfg` that boots the kernel with the initramfs via serial console.
5. **Disk image** — A 64 MB GPT-partitioned image with an EFI System Partition containing the GRUB EFI bootloader, kernel (`vmlinuz`), and initramfs — ready for UEFI boot in QEMU.
6. **`make run`** — Launches QEMU with KVM, OVMF firmware, e1000 NIC (user-mode networking, DHCP), and serial console on stdio.
