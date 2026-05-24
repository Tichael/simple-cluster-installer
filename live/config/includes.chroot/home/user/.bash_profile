#!/bin/bash
# Auto-launch the installer when the default live user logs in on tty1.
if [[ "$(tty)" == "/dev/tty1" && -x /opt/simple-cluster-installer/install.sh ]]; then
    exec sudo /opt/simple-cluster-installer/install.sh
fi
