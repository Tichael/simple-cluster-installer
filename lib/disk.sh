#!/bin/bash
# Disk partitioning, LVM setup, formatting, and mounting for the ABRoot
# LVM thin-provisioning layout.
#
# Actual layout (based on a fresh Vanilla OS Orchid install):
#
#   Partition 1: vos-boot   1 GiB    ext4   /boot      (GRUB lives here)
#   Partition 2: vos-efi    512 MiB  vfat   /boot/efi
#   Partition 3: (LVM PV)   <ROOT_LVM_SIZE_GIB>  → VG vos-root
#   Partition 4: (LVM PV)   rest of disk          → VG vos-var
#
#   VG vos-root:
#     LV init        1 GiB  ext4   label "vos-init"  (kernel/initramfs, read by GRUB)
#     thin-pool root-tpool  <remaining space>
#       thin LV root-a  btrfs  label "vos-a"  (active root on first boot)
#       thin LV root-b  btrfs  label "vos-b"  (inactive; used by ABRoot for updates)
#
#   VG vos-var:
#     LV var  100%  btrfs  label "vos-var"  (/var, shared between A and B)
#
# All labels must match the values in abroot.json inside the image
# (/usr/share/abroot/abroot.json). Do not rename them.

# Tracks mounted paths for ordered cleanup.
declare -a _MOUNTS=()

# Returns a list of suitable block devices as "<dev>\t<size> <model>" lines.
disk_list_devices() {
    lsblk -dpno NAME,SIZE,MODEL \
        | grep -v -E "loop|sr[0-9]+|fd[0-9]+" \
        | awk '{printf "%s\t%s %s\n", $1, $2, substr($0, index($0,$3))}'
}

# Prompts the user to choose a disk. Prints the selected path to stdout.
# Usage: disk_select <role_label> <whiptail_message>
disk_select() {
    local role="$1" msg="$2"
    local items=()
    while IFS=$'\t' read -r dev desc; do
        items+=("$dev" "$desc")
    done < <(disk_list_devices)

    if [[ ${#items[@]} -eq 0 ]]; then
        echo "No suitable disks found." >&2
        exit 1
    fi

    whiptail --title "Select $role disk" \
        --menu "$msg" 20 72 10 "${items[@]}" 3>&1 1>&2 2>&3
}

# Returns the partition device path for partition N on a disk.
# Handles the "p" suffix for NVMe/eMMC devices (nvme0n1p1, mmcblk0p1).
_part() {
    local disk="$1" n="$2"
    if [[ "$disk" =~ nvme|mmcblk ]]; then
        echo "${disk}p${n}"
    else
        echo "${disk}${n}"
    fi
}

_check_disk_size() {
    local disk="$1" root_lvm_gib="$2"
    local disk_basename sector_size disk_sectors disk_gib
    disk_basename=$(basename "$disk")
    sector_size=$(cat "/sys/block/$disk_basename/queue/logical_block_size" 2>/dev/null || echo 512)
    disk_sectors=$(cat "/sys/block/$disk_basename/size")
    disk_gib=$(( disk_sectors * sector_size / 1024 / 1024 / 1024 ))

    # Minimum: 1G boot + 1G efi (round up) + root_lvm + 8G var minimum
    local min_gib=$(( 2 + root_lvm_gib + 8 ))
    if [[ $disk_gib -lt $min_gib ]]; then
        echo "Disk $disk is too small (${disk_gib} GiB). Minimum for this layout: ${min_gib} GiB." >&2
        exit 1
    fi
    echo "$disk_gib"
}

# Creates 4 GPT partitions for the ABRoot LVM layout.
# Usage: disk_partition <disk> <root_lvm_size_gib>
disk_partition() {
    local disk="$1" root_lvm_gib="$2"

    _check_disk_size "$disk" "$root_lvm_gib" > /dev/null

    sgdisk --zap-all "$disk"
    sgdisk -n "1:0:+1G"                   -t 1:8300 -c 1:"vos-boot"  "$disk"  # ext4 /boot
    sgdisk -n "2:0:+512M"                 -t 2:ef00 -c 2:"vos-efi"   "$disk"  # vfat /boot/efi
    sgdisk -n "3:0:+${root_lvm_gib}G"    -t 3:8e00 -c 3:""           "$disk"  # LVM PV → vos-root VG
    sgdisk -n "4:0:0"                     -t 4:8e00 -c 4:""           "$disk"  # LVM PV → vos-var VG

    partprobe "$disk"
    sleep 2
}

# Creates LVM VGs, thin pool, and all logical volumes.
# Usage: disk_setup_lvm <disk> <root_lvm_size_gib>
disk_setup_lvm() {
    local disk="$1" root_lvm_gib="$2"
    local pv_root pv_var
    pv_root=$(_part "$disk" 3)
    pv_var=$(_part  "$disk" 4)

    pvcreate -ff -y "$pv_root"
    pvcreate -ff -y "$pv_var"
    vgcreate vos-root "$pv_root"
    vgcreate vos-var  "$pv_var"

    # vos-root VG: 1 GiB init LV + thin pool consuming the rest.
    lvcreate -y -L 1G -n init vos-root
    lvcreate -y --type thin-pool -l 100%FREE --thinpool root-tpool vos-root

    # Virtual size for each thin LV: pool size minus init and LVM overhead.
    local thin_virt_gib=$(( root_lvm_gib - 3 ))
    [[ $thin_virt_gib -lt 5 ]] && thin_virt_gib=5
    lvcreate -y -V "${thin_virt_gib}G" --thin -n root-a vos-root/root-tpool
    lvcreate -y -V "${thin_virt_gib}G" --thin -n root-b vos-root/root-tpool

    # vos-var VG: single LV consuming the entire VG.
    lvcreate -y -l 100%FREE -n var vos-var
}

# Formats all filesystems with the correct types and labels.
disk_format() {
    local disk="$1"
    mkfs.ext4  -L "vos-boot"  "$(_part "$disk" 1)"
    mkfs.vfat  -F32 -n "vos-efi"  "$(_part "$disk" 2)"
    mkfs.ext4  -L "vos-init"  /dev/vos-root/init
    mkfs.btrfs -L "vos-a"     /dev/vos-root/root-a
    mkfs.btrfs -L "vos-b"     /dev/vos-root/root-b
    mkfs.btrfs -L "vos-var"   /dev/vos-var/var
}

# Mounts vos-a (root) and vos-var (/var) under a temp directory.
# vos-boot and vos-efi are NOT mounted here; call disk_mount_boot after
# deploy_init_lv so kernels are staged before vos-boot shadows /boot.
# Prints the mount root path to stdout.
disk_mount_root() {
    local disk="$1"
    local mnt
    mnt=$(mktemp -d /mnt/sc-install.XXXX)

    _mount /dev/vos-root/root-a "$mnt"
    mkdir -p "$mnt/var"
    _mount /dev/vos-var/var "$mnt/var"

    echo "$mnt"
}

# Mounts vos-boot (/boot) and vos-efi (/boot/efi) under the target.
# Call this AFTER deploy_init_lv so the kernel files are already staged
# to the init LV before vos-boot is mounted over /boot.
disk_mount_boot() {
    local disk="$1" target="$2"
    mkdir -p "$target/boot/efi" "$target/boot/init"
    _mount "$(_part "$disk" 1)" "$target/boot"
    mkdir -p "$target/boot/efi" "$target/boot/init"
    _mount "$(_part "$disk" 2)" "$target/boot/efi"
}

# Bind-mounts the live environment's special filesystems into the target.
# Call before chroot operations; call disk_unbind_special after.
disk_bind_special() {
    local mnt="$1"
    _mount --bind /dev     "$mnt/dev"
    _mount --bind /dev/pts "$mnt/dev/pts"
    _mount --bind /proc    "$mnt/proc"
    _mount --bind /sys     "$mnt/sys"
}

disk_unbind_special() {
    local mnt="$1"
    umount "$mnt/sys"     2>/dev/null || true
    umount "$mnt/proc"    2>/dev/null || true
    umount "$mnt/dev/pts" 2>/dev/null || true
    umount "$mnt/dev"     2>/dev/null || true
}

# Unmounts everything mounted by disk_mount_root / disk_mount_boot in reverse order.
disk_umount() {
    local mnt="$1"
    for ((i = ${#_MOUNTS[@]} - 1; i >= 0; i--)); do
        umount "${_MOUNTS[$i]}" 2>/dev/null || true
    done
    rmdir "$mnt" 2>/dev/null || true
    _MOUNTS=()
}

_mount() {
    mount "$@"
    _MOUNTS+=("${@: -1}")
}
