#!/bin/bash
# Auto-launch the installer when logged in on tty1.
if [[ "$(tty)" == "/dev/tty1" && -x /opt/simple-cluster-installer/install.sh ]]; then
    exec /opt/simple-cluster-installer/install.sh
fi
