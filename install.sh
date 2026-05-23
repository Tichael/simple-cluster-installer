#!/bin/bash
# Simple Cluster Installer — entry point.
#
# Installs the simple-cluster OS onto a target disk using ABRoot's LVM
# thin-provisioning A/B layout. Run from a Debian/Ubuntu live environment
# as root (e.g. a Debian netinst or Ubuntu live USB in rescue mode).
#
# Dependencies (install with apt-get before running):
#   whiptail gdisk dosfstools e2fsprogs btrfs-progs lvm2 podman grub-efi-amd64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_REF="${IMAGE_REF:-ghcr.io/tichael/simple-cluster:main}"

# Size in GiB for the LVM physical volume that hosts the root A/B thin pool.
# The var PV receives all remaining disk space.
# Minimum recommended: 24 GiB (1 GiB init + ~2 GiB LVM overhead + ~21 GiB pool).
ROOT_LVM_SIZE_GIB="${ROOT_LVM_SIZE_GIB:-40}"

source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/disk.sh"
source "$SCRIPT_DIR/lib/deploy.sh"
source "$SCRIPT_DIR/lib/config.sh"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This installer must be run as root." >&2
        exit 1
    fi
}

check_deps() {
    local missing=()
    local deps=(whiptail sgdisk mkfs.vfat mkfs.ext4 mkfs.btrfs
                pvcreate vgcreate lvcreate lvs
                podman grub-install blkid findfs chpasswd)
    for cmd in "${deps[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "Install with: apt-get install -y whiptail gdisk dosfstools e2fsprogs" >&2
        echo "              btrfs-progs lvm2 podman grub-efi-amd64" >&2
        exit 1
    fi
}

main() {
    check_root
    check_deps
    ui_welcome

    # --- Disk selection ---
    ROOT_DISK=$(disk_select "root" \
        "Select the disk to install the OS on.\nWARNING: This disk will be completely erased.")
    [[ -z "$ROOT_DISK" ]] && { echo "No disk selected. Aborting."; exit 1; }

    # --- System configuration ---
    HOSTNAME=$(config_ask_hostname)
    USERNAME=$(config_ask_username)
    PASSWORD=$(config_ask_password)
    SSH_KEY=$(config_ask_ssh_key)
    NETWORK_CONFIG=$(config_ask_network)

    # --- Confirmation ---
    ui_confirm "Ready to install" \
        "Disk:       $ROOT_DISK\nRoot LVM:   ${ROOT_LVM_SIZE_GIB} GiB\nHostname:   $HOSTNAME\nUser:       $USERNAME\n\nAll data on $ROOT_DISK will be destroyed.\nProceed?"

    # --- Partitioning and LVM setup ---
    ui_step "Partitioning $ROOT_DISK..."
    disk_partition "$ROOT_DISK" "$ROOT_LVM_SIZE_GIB"

    ui_step "Setting up LVM volumes..."
    disk_setup_lvm "$ROOT_DISK" "$ROOT_LVM_SIZE_GIB"

    ui_step "Formatting filesystems..."
    disk_format "$ROOT_DISK"

    # --- Image deployment ---
    # Mount only vos-a + vos-var; vos-boot is mounted after kernel staging.
    ui_step "Mounting root filesystems..."
    MOUNT_ROOT=$(disk_mount_root "$ROOT_DISK")

    ui_step "Deploying OS image ($IMAGE_REF)..."
    deploy_image "$IMAGE_REF" "$MOUNT_ROOT"

    # Stage kernels to init LV before mounting vos-boot over /boot.
    ui_step "Staging kernels to init LV..."
    deploy_init_lv "$MOUNT_ROOT"

    # Mount boot partition (shadows /boot extracted from the image).
    disk_mount_boot "$ROOT_DISK" "$MOUNT_ROOT"

    ui_step "Installing bootloader..."
    deploy_bootloader "$ROOT_DISK" "$MOUNT_ROOT"

    # --- System configuration ---
    ui_step "Configuring system..."
    config_apply "$MOUNT_ROOT" "$HOSTNAME" "$USERNAME" "$PASSWORD" "$SSH_KEY" "$NETWORK_CONFIG"

    ui_step "Unmounting filesystems..."
    disk_umount "$MOUNT_ROOT"

    ui_finish "$ROOT_DISK"
}

main "$@"
