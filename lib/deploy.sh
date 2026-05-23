#!/bin/bash
# Deploy the OCI image to the target root filesystem and install GRUB.

# Pulls the OCI image and extracts it to the target directory.
# Boot files are correctly staged so the boot partition contains the kernel.
# Usage: deploy_image <image_ref> <target_root>
deploy_image() {
    local image_ref="$1" target="$2"

    echo "Pulling $image_ref..."
    podman pull "$image_ref"

    local cid
    cid=$(podman create "$image_ref" /bin/true)

    # Extract the full rootfs, preserving numeric owners and permissions.
    echo "Extracting rootfs to $target..."
    podman export "$cid" | tar -xp --numeric-owner -C "$target"
    podman rm "$cid"

    # Ensure required mount-point directories exist (podman export may omit them).
    mkdir -p "$target"/{dev,proc,sys,run,tmp}
    chmod 1777 "$target/tmp"

    # The boot partition is already mounted at $target/boot (empty).
    # Move the kernel and initramfs from the extracted rootfs into it.
    # (The image's /boot content was shadowed when the boot partition was mounted.)
    _stage_boot_files "$target"
}

# Copies kernel/initramfs files from the image into the mounted boot partition.
# This is needed because disk_mount mounts the boot partition over /boot,
# which shadows the /boot content extracted from the image.
_stage_boot_files() {
    local target="$1"
    local boot_stage
    boot_stage=$(mktemp -d /tmp/sc-boot-stage.XXXX)

    # Re-mount the boot partition in the staging area to access its contents.
    local boot_dev
    boot_dev=$(findfs LABEL=vos-boot 2>/dev/null || true)
    if [[ -z "$boot_dev" ]]; then
        echo "Warning: could not find vos-boot partition for boot staging." >&2
        rmdir "$boot_stage"
        return 0
    fi

    # The boot partition is already mounted at $target/boot.
    # We need to copy the /boot files from the image there.
    # Since extraction happened before mounting, /boot inside the image was
    # written to $target/boot but then overridden by the partition mount.
    # Re-export just the /boot directory from the image and copy it.
    local image_ref
    image_ref=$(podman images --format "{{.Repository}}:{{.Tag}}" | head -1)

    cid=$(podman create "$image_ref" /bin/true)
    podman export "$cid" | tar -xp --numeric-owner -C "$boot_stage" ./boot 2>/dev/null || \
        podman export "$cid" | tar -xp --numeric-owner -C "$boot_stage" boot 2>/dev/null || true
    podman rm "$cid"

    if [[ -d "$boot_stage/boot" ]]; then
        cp -a "$boot_stage/boot/." "$target/boot/"
    fi

    rm -rf "$boot_stage"
}

# Installs GRUB (EFI) and generates the initial GRUB configuration.
# Usage: deploy_bootloader <disk> <target_root>
deploy_bootloader() {
    local disk="$1" target="$2"

    disk_bind_special "$target"

    # grub-install writes EFI files to /boot/efi and the GRUB core to /boot/grub.
    chroot "$target" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=simple-cluster \
        --recheck \
        "$disk" \
        || { echo "grub-install failed. Check that grub-efi-amd64 is installed in the image." >&2; disk_unbind_special "$target"; exit 1; }

    chroot "$target" grub-mkconfig -o /boot/grub/grub.cfg

    disk_unbind_special "$target"
}
