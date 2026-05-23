#!/bin/bash
# TUI helpers using whiptail.

ui_welcome() {
    whiptail --title "Simple Cluster Installer" \
        --msgbox "Welcome to the Simple Cluster Installer.\n\nThis will install the simple-cluster hyperconverged OS on your chosen disk.\n\nMake sure you have:\n  - An internet connection (to pull the image)\n  - Identified which disk to install to\n\nStorage disks for LINSTOR are configured separately after first boot." \
        15 64
}

ui_step() {
    echo "[*] $*"
}

ui_confirm() {
    local title="$1" msg="$2"
    whiptail --title "$title" --yesno "$msg" 14 64
}

ui_finish() {
    local disk="$1"
    whiptail --title "Installation Complete" \
        --msgbox "Installation complete!\n\nThe OS has been installed to $disk.\nRemove the installation media and reboot.\n\nOn first boot, configure LINSTOR storage with:\n  sudo cluster-storage-setup" \
        14 64
}
