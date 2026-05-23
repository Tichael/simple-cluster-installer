# simple-cluster-installer

A minimal shell script installer for [simple-cluster](https://github.com/Tichael/simple-cluster-image) — a hyperconverged cluster OS built on [Vanilla OS](https://vanillaos.org/) / [ABRoot](https://github.com/Vanilla-OS/ABRoot).

## What it does

1. Guides you through disk selection, hostname, admin user, SSH key, and network setup via a TUI
2. Partitions the target disk and sets up LVM with thin provisioning for ABRoot's A/B layout
3. Pulls and deploys `ghcr.io/tichael/simple-cluster:main` from GHCR
4. Stages the kernel and initramfs to the init LV (read directly by GRUB via LVM)
5. Installs GRUB for UEFI boot with the ABRoot chainload configuration
6. Writes `/etc/fstab`, hostname, user, SSH key, and systemd-networkd configuration

LINSTOR/DRBD storage is configured separately after first boot. Data disks are not touched.

## Requirements

Boot from a **Debian or Ubuntu live USB** (any recent version), then install dependencies:

```bash
apt-get install -y whiptail gdisk dosfstools e2fsprogs btrfs-progs lvm2 podman grub-efi-amd64
```

An internet connection is required to pull the image from GHCR.

## Usage

```bash
git clone https://github.com/Tichael/simple-cluster-installer
cd simple-cluster-installer
sudo ./install.sh
```

To override the image ref or root LVM size:

```bash
sudo IMAGE_REF="ghcr.io/tichael/simple-cluster:v1.2.3" \
     ROOT_LVM_SIZE_GIB=60 \
     ./install.sh
```

## Disk layout

The installer creates 4 GPT partitions and two LVM Volume Groups:

| Device / Label     | Default size      | Filesystem | Mount point  | Purpose                               |
|--------------------|-------------------|------------|--------------|---------------------------------------|
| Part 1 `vos-boot`  | 1 GiB             | ext4       | `/boot`      | GRUB bootloader                       |
| Part 2 `vos-efi`   | 512 MiB           | FAT32      | `/boot/efi`  | EFI System Partition                  |
| Part 3             | `ROOT_LVM_SIZE_GIB` | LVM PV   | —            | VG `vos-root` (see below)             |
| Part 4             | remaining         | LVM PV     | —            | VG `vos-var` (see below)              |

**VG `vos-root`** (on partition 3):

| LV / Label        | Size       | Filesystem | Purpose                                     |
|-------------------|------------|------------|---------------------------------------------|
| `init` / `vos-init` | 1 GiB    | ext4       | Kernel + initramfs; GRUB reads via LVM      |
| thin-pool `root-tpool` | rest  | —          | LVM thin pool for root A and B              |
| `root-a` / `vos-a` | `ROOT_LVM_SIZE_GIB − 3` GiB (virtual) | btrfs | Root A — active on first boot |
| `root-b` / `vos-b` | same (virtual) | btrfs | Root B — inactive; used by ABRoot for updates |

**VG `vos-var`** (on partition 4):

| LV / Label       | Size  | Filesystem | Mount point | Purpose                         |
|------------------|-------|------------|-------------|---------------------------------|
| `var` / `vos-var` | 100% | btrfs      | `/var`      | Persistent state (Docker, DRBD) |

All LV labels must match the values in `/usr/share/abroot/abroot.json` inside the image. Do not rename them.

### Minimum disk size

`2 GiB (boot+efi) + ROOT_LVM_SIZE_GIB + 8 GiB (min var)`. With the default `ROOT_LVM_SIZE_GIB=40`, the minimum is **~50 GiB**; 100 GiB+ is recommended for production.

## Environment variables

| Variable            | Default                               | Description                                    |
|---------------------|---------------------------------------|------------------------------------------------|
| `IMAGE_REF`         | `ghcr.io/tichael/simple-cluster:main` | OCI image to deploy                            |
| `ROOT_LVM_SIZE_GIB` | `40`                                  | Size of the LVM root PV (GiB); var gets the rest |

## Boot flow

GRUB → reads `grub.cfg` from `vos-boot` → `configfile "/vos-a/abroot.cfg"` on the init LV (GRUB device `lvm/vos--root-init`) → `linux … root=UUID=<vos-a-uuid>` → kernel mounts vos-a as `/`.

On ABRoot updates, the new root is staged in vos-b and the init LV's `/vos-b/abroot.cfg` is populated. GRUB's "Previous State (B)" entry gives a rollback path.

## Notes

- **UEFI only.** Legacy BIOS boot is not supported.
- **x86-64 only.**
- Root disk mirroring (RAID 1) is not yet supported but is planned.
- The `grub-efi-amd64` package must be present in the installed image (it is in the Vanilla OS core base).
- Encryption support is planned but not yet implemented.
