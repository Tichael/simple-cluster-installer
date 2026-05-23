#!/bin/bash
# Deploy the OCI image, stage kernels to the init LV, and install GRUB.
#
# ABRoot boot flow:
#   GRUB reads grub.cfg from vos-boot (/boot/grub/grub.cfg).
#   grub.cfg uses configfile to chain-load /vos-a/abroot.cfg from the init LV
#   (GRUB device path: lvm/vos--root-init).
#   abroot.cfg contains the linux/initrd directives with root=UUID=<vos-a-uuid>.

# Pulls the OCI image and extracts the rootfs to the target directory.
# vos-boot must NOT be mounted at this point; it is mounted by disk_mount_boot
# after deploy_init_lv so that kernel staging can read from $target/boot.
# Usage: deploy_image <image_ref> <target_root>
deploy_image() {
    local image_ref="$1" target="$2"

    echo "Pulling $image_ref..."
    podman pull "$image_ref"

    local cid
    cid=$(podman create "$image_ref" /bin/true)

    echo "Extracting rootfs to $target..."
    podman export "$cid" | tar -xp --numeric-owner -C "$target"
    podman rm "$cid"

    # Ensure required directories exist (podman export may omit some).
    mkdir -p "$target"/{dev,proc,sys,run,tmp,boot,var}
    chmod 1777 "$target/tmp"

    # ABRoot uses this file at the root of vos-a to track the deployed image.
    local digest timestamp
    digest=$(podman image inspect --format '{{index .RepoDigests 0}}' "$image_ref" 2>/dev/null \
             | awk -F'@' '{print $2}')
    [[ -z "$digest" ]] && digest="sha256:unknown"
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000000000+00:00")
    cat > "$target/abimage.abr" <<EOF
{
    "digest":"${digest}",
    "timestamp":"${timestamp}",
    "image":"${image_ref}"
}
EOF
}

# Stages the kernel and initramfs from the extracted rootfs to the init LV,
# and writes the GRUB chainload config (abroot.cfg) for vos-a.
#
# The init LV (vos-root/init, ext4, label "vos-init") is GRUB-readable via
# (lvm/vos--root-init). It holds:
#   /vos-a/vmlinuz-<version>
#   /vos-a/initrd.img-<version>
#   /vos-a/abroot.cfg          ← GRUB loads this via configfile
#   /vos-b/                    ← empty; populated by ABRoot on first update
#
# Usage: deploy_init_lv <target_root>
deploy_init_lv() {
    local target="$1"
    local init_staging
    init_staging=$(mktemp -d /tmp/vos-init-staging.XXXX)
    mount /dev/vos-root/init "$init_staging"

    mkdir -p "$init_staging/vos-a" "$init_staging/vos-b"

    # Find the highest-versioned kernel in the extracted rootfs.
    local vmlinuz kernel_version
    vmlinuz=$(ls "$target/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
    if [[ -z "$vmlinuz" ]]; then
        echo "Error: no kernel found at $target/boot/vmlinuz-*" >&2
        umount "$init_staging"
        rmdir "$init_staging"
        exit 1
    fi
    kernel_version="${vmlinuz##*/vmlinuz-}"
    echo "Staging kernel $kernel_version to init LV..."

    cp "$target/boot/vmlinuz-${kernel_version}"    "$init_staging/vos-a/"
    cp "$target/boot/initrd.img-${kernel_version}" "$init_staging/vos-a/"
    [[ -f "$target/boot/config-${kernel_version}" ]] \
        && cp "$target/boot/config-${kernel_version}"     "$init_staging/vos-a/"
    [[ -f "$target/boot/System.map-${kernel_version}" ]] \
        && cp "$target/boot/System.map-${kernel_version}" "$init_staging/vos-a/"

    # The root= parameter uses the UUID of the vos-a btrfs LV (not a label).
    local vos_a_uuid
    vos_a_uuid=$(blkid -s UUID -o value /dev/vos-root/root-a)

    # Write the GRUB chainload config for vos-a.
    # $vt_handoff is a GRUB variable set at runtime; escape it in the heredoc.
    cat > "$init_staging/vos-a/abroot.cfg" <<EOF
insmod gzio
insmod part_gpt
insmod ext2
linux   (lvm/vos--root-init)/vos-a/vmlinuz-${kernel_version} root=UUID=${vos_a_uuid} quiet bgrt_disable \$vt_handoff lsm=integrity
initrd  (lvm/vos--root-init)/vos-a/initrd.img-${kernel_version}
EOF

    umount "$init_staging"
    rmdir "$init_staging"
}

# Installs GRUB (EFI) and writes the ABRoot-style grub.cfg.
# Must be called after disk_mount_boot (vos-boot mounted at $target/boot).
# Usage: deploy_bootloader <disk> <target_root>
deploy_bootloader() {
    local disk="$1" target="$2"

    disk_bind_special "$target"

    chroot "$target" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=simple-cluster \
        --recheck \
        "$disk" \
        || {
            echo "grub-install failed. Ensure grub-efi-amd64 is installed in the image." >&2
            disk_unbind_special "$target"
            exit 1
        }

    disk_unbind_special "$target"

    # Write the ABRoot-style grub.cfg directly.
    # Do NOT use grub-mkconfig: it generates standard linux menuentry blocks
    # instead of the configfile-based chainload that ABRoot requires.
    mkdir -p "$target/boot/grub"
    cat > "$target/boot/grub/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=5

if [ -s $prefix/grubenv ]; then
    set have_grubenv=true
    load_env
fi

if [ "${next_entry}" ] ; then
    set default="${next_entry}"
    set next_entry=
    save_env next_entry
    set boot_once=true
fi

insmod part_gpt
insmod lvm
insmod ext2

# AUTO GENERATED BY ABROOT
menuentry "Current State (A)" --class abroot-a {
    set root=(lvm/vos--root-init)
    configfile "/vos-a/abroot.cfg"
}

menuentry "Previous State (B)" --class abroot-b {
    set root=(lvm/vos--root-init)
    configfile "/vos-b/abroot.cfg"
}
# END - AUTO GENERATED BY ABROOT
GRUBCFG
}
