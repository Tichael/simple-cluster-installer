#!/bin/bash
# Simple Cluster Installer — entry point.
#
# Installs the simple-cluster OS onto a target disk using ABRoot's
# A/B partition layout. Run from a Debian/Ubuntu live environment as root.
#
# Dependencies: whiptail gdisk dosfstools e2fsprogs podman grub-efi-amd64
#   Install with: apt-get install -y whiptail gdisk dosfstools e2fsprogs \
#                   podman grub-efi-amd64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_REF="ghcr.io/tichael/simple-cluster:main"

# Size in GiB for each partition (override via environment variables).
EFI_SIZE_MIB="${EFI_SIZE_MIB:-512}"
BOOT_SIZE_GIB="${BOOT_SIZE_GIB:-1}"
VAR_SIZE_GIB="${VAR_SIZE_GIB:-32}"
# Root A and B each receive roughly half of the remaining space.

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
    for cmd in whiptail sgdisk mkfs.vfat mkfs.ext4 podman grub-install blkid findfs chpasswd; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "Install with: apt-get install -y whiptail gdisk dosfstools e2fsprogs podman grub-efi-amd64" >&2
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
        "Disk:     $ROOT_DISK\nHostname: $HOSTNAME\nUser:     $USERNAME\n\nAll data on $ROOT_DISK will be destroyed.\nProceed?"

    # --- Installation ---
    ui_step "Partitioning $ROOT_DISK..."
    disk_partition "$ROOT_DISK" "$EFI_SIZE_MIB" "$BOOT_SIZE_GIB" "$VAR_SIZE_GIB"

    ui_step "Formatting partitions..."
    disk_format "$ROOT_DISK"

    ui_step "Mounting filesystems..."
    MOUNT_ROOT=$(disk_mount "$ROOT_DISK")

    ui_step "Deploying OS image ($IMAGE_REF)..."
    deploy_image "$IMAGE_REF" "$MOUNT_ROOT"

    ui_step "Installing bootloader..."
    deploy_bootloader "$ROOT_DISK" "$MOUNT_ROOT"

    ui_step "Configuring system..."
    config_apply "$MOUNT_ROOT" "$HOSTNAME" "$USERNAME" "$PASSWORD" "$SSH_KEY" "$NETWORK_CONFIG"

    ui_step "Unmounting filesystems..."
    disk_umount "$MOUNT_ROOT"

    ui_finish "$ROOT_DISK"
}

main "$@"
