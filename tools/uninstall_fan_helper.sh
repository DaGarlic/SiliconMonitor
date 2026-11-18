#!/bin/zsh
# Removes the fan-control helper daemon (needs admin rights). The fans go back to automatic.
set -e
LABEL=local.siliconmonitor.fanhelper
sudo launchctl bootout system/$LABEL 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL /var/run/local.siliconmonitor.fan.sock
echo "Removed $LABEL"
