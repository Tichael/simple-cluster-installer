#!/bin/bash
# Disk partitioning, formatting, and mounting for the ABRoot layout.
#
# ABRoot identifies partitions by GPT label. The required labels are:
#   vos-efi   — EFI System Partition   (/boot/efi)
#   vos-boot  — Bootloader & kernels   (/boot)
#   vos-var   — Persistent state       (/var, shared across A/B)
#   vos-a     — Root filesystem A      (active on first boot)
#   vos-b     — Root filesystem B      (inactive; used by ABRoot for updates)
#
# These labels must match what is set in abroot.json inside the image
# (/usr/share/abroot/abroot.json). Do not rename them.

# Tracks mounted paths in reverse-unmount order.
declare -a _MOUNTS=()

# Returns a list of suitable block devices as "<dev>\t<size> <model>" lines.
disk_list_devices() {
    lsblk -dpno NAME,SIZE,MODEL \
        | grep -v -E "loop|sr[0-9]+|fd[0-9]+" \
        | awk '{printf "%s\t%s %s\n", $1, $2, substr($0, index($0,$3))}'
}

# Prompt the user to choose a disk.
# Usage: disk_select <role_label> <whiptail_message>
# Prints the selected device path to stdout.
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

# Returns the partition device path for partition number N on a given disk.
# Handles the "p" suffix for NVMe/eMMC devices (e.g. nvme0n1p1, sda1).
_part() {
    local disk="$1" n="$2"
    if [[ "$disk" =~ nvme|mmcblk ]]; then
        echo "${disk}p${n}"
    else
        echo "${disk}${n}"
    fi
}

# Checks that the disk is large enough for the requested layout.
# Usage: _check_disk_size <disk> <efi_mib> <boot_gib> <var_gib>
_check_disk_size() {
    local disk="$1" efi_mib="$2" boot_gib="$3" var_gib="$4"
    local disk_basename sector_size disk_sectors disk_gib
    disk_basename=$(basename "$disk")
    sector_size=$(cat "/sys/block/$disk_basename/queue/logical_block_size" 2>/dev/null || echo 512)
    disk_sectors=$(cat "/sys/block/$disk_basename/size")
    disk_gib=$(( disk_sectors * sector_size / 1024 / 1024 / 1024 ))

    # Minimum: efi + boot + var + 2 * min_root (10 GiB each)
    local min_gib=$(( (efi_mib / 1024) + boot_gib + var_gib + 20 ))
    if [[ $disk_gib -lt $min_gib ]]; then
        echo "Disk $disk is too small (${disk_gib} GiB). Minimum required: ${min_gib} GiB." >&2
        exit 1
    fi
    echo "$disk_gib"
}

# Partitions the disk with the ABRoot layout.
# Usage: disk_partition <disk> <efi_mib> <boot_gib> <var_gib>
disk_partition() {
    local disk="$1" efi_mib="$2" boot_gib="$3" var_gib="$4"

    local disk_gib
    disk_gib=$(_check_disk_size "$disk" "$efi_mib" "$boot_gib" "$var_gib")

    # Remaining space after EFI, boot, var (in GiB, rough estimate).
    local overhead_gib=1  # GPT overhead + alignment slack
    local used_gib=$(( (efi_mib / 1024) + boot_gib + var_gib + overhead_gib ))
    local remaining_gib=$(( disk_gib - used_gib ))
    local root_gib=$(( remaining_gib / 2 ))

    echo "Disk: ${disk_gib} GiB total, ${root_gib} GiB per root partition"

    sgdisk --zap-all "$disk"

    sgdisk -n "1:0:+${efi_mib}M"   -t 1:ef00 -c 1:"vos-efi"  "$disk"
    sgdisk -n "2:0:+${boot_gib}G"  -t 2:8300 -c 2:"vos-boot" "$disk"
    sgdisk -n "3:0:+${var_gib}G"   -t 3:8300 -c 3:"vos-var"  "$disk"
    sgdisk -n "4:0:+${root_gib}G"  -t 4:8300 -c 4:"vos-a"    "$disk"
    sgdisk -n "5:0:0"               -t 5:8300 -c 5:"vos-b"    "$disk"

    partprobe "$disk"
    sleep 2
}

# Formats all ABRoot partitions.
disk_format() {
    local disk="$1"
    mkfs.vfat -F32 -n "vos-efi"  "$(_part "$disk" 1)"
    mkfs.ext4 -L   "vos-boot"    "$(_part "$disk" 2)"
    mkfs.ext4 -L   "vos-var"     "$(_part "$disk" 3)"
    mkfs.ext4 -L   "vos-a"       "$(_part "$disk" 4)"
    mkfs.ext4 -L   "vos-b"       "$(_part "$disk" 5)"
}

# Mounts the ABRoot layout under a temp directory.
# Prints the mount root path to stdout.
disk_mount() {
    local disk="$1"
    local mnt
    mnt=$(mktemp -d /mnt/sc-install.XXXX)

    _mount "$(_part "$disk" 4)" "$mnt"
    mkdir -p "$mnt/boot" "$mnt/boot/efi" "$mnt/var"
    _mount "$(_part "$disk" 2)" "$mnt/boot"
    _mount "$(_part "$disk" 1)" "$mnt/boot/efi"
    # vos-var is left unmounted here; it is mounted by the OS at runtime.
    # The /var directory must still exist in the root filesystem.

    echo "$mnt"
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

# Unmounts everything mounted by disk_mount.
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
    # Record the last argument (the mount point) for cleanup.
    _MOUNTS+=("${@: -1}")
}
