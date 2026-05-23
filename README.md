# simple-cluster-installer

A minimal shell script installer for [simple-cluster](https://github.com/Tichael/simple-cluster-image) — a hyperconverged cluster OS built on [Vanilla OS](https://vanillaos.org/) / [ABRoot](https://github.com/Vanilla-OS/ABRoot).

## What it does

1. Guides you through disk selection, hostname, admin user, SSH key, and network setup via a TUI
2. Partitions the target disk for ABRoot's A/B atomic update layout
3. Pulls and deploys `ghcr.io/tichael/simple-cluster:main` from GHCR
4. Installs GRUB for UEFI boot
5. Writes `/etc/fstab`, hostname, user, SSH key, and systemd-networkd configuration

LINSTOR/DRBD storage is configured separately after first boot. Data disks are not touched.

## Requirements

Boot from a **Debian or Ubuntu live USB** (any recent version), then install dependencies:

```bash
apt-get install -y whiptail gdisk dosfstools e2fsprogs podman grub-efi-amd64
```

An internet connection is required to pull the image from GHCR.

## Usage

```bash
git clone https://github.com/Tichael/simple-cluster-installer
cd simple-cluster-installer
sudo ./install.sh
```

To override the image tag or partition sizes:

```bash
sudo IMAGE_REF="ghcr.io/tichael/simple-cluster:v1.2.3" \
     VAR_SIZE_GIB=64 \
     ./install.sh
```

## Disk layout

| GPT label  | Default size | Filesystem | Mount point | Purpose                              |
|------------|-------------|------------|-------------|--------------------------------------|
| `vos-efi`  | 512 MiB     | FAT32      | `/boot/efi` | EFI System Partition                 |
| `vos-boot` | 1 GiB       | ext4       | `/boot`     | Bootloader & kernels                 |
| `vos-var`  | 32 GiB      | ext4       | `/var`      | Persistent state (ABRoot + Docker)   |
| `vos-a`    | ~half       | ext4       | `/`         | Root A — active on first boot        |
| `vos-b`    | ~half       | ext4       | —           | Root B — inactive, used for updates  |

The GPT labels must match what is configured in `/usr/share/abroot/abroot.json` inside the image. Do not rename them.

### Minimum disk size

`EFI + boot + var + 20 GiB` (2 × 10 GiB minimum per root). The default layout requires at least **~74 GiB**.

## Environment variables

| Variable         | Default                                  | Description                        |
|------------------|------------------------------------------|------------------------------------|
| `IMAGE_REF`      | `ghcr.io/tichael/simple-cluster:main`    | OCI image to deploy                |
| `EFI_SIZE_MIB`   | `512`                                    | EFI partition size in MiB          |
| `BOOT_SIZE_GIB`  | `1`                                      | Boot partition size in GiB         |
| `VAR_SIZE_GIB`   | `32`                                     | /var partition size in GiB         |

## Notes

- **UEFI only.** Legacy BIOS boot is not supported.
- **x86-64 only.**
- Root disk mirroring (RAID 1) is not yet supported but is planned.
- The `grub-efi-amd64` package must be present in the installed image (it is in the Vanilla OS core base).
- After installation, ABRoot manages atomic updates by transacting between `vos-a` and `vos-b`.
