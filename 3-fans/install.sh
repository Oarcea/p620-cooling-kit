#!/usr/bin/env bash
# Step 3: install the p620-fans service (P100 shroud fans, CPU cooler, rear + front fans).
# (On a fresh OS the "replacing p620-gpu-fans" part does nothing; it only upgraded the first version.)
# Run: sudo bash install.sh
# Uninstall:
#   sudo systemctl disable --now p620-fans
#   sudo rm /etc/systemd/system/p620-fans.service /usr/local/sbin/p620-fans /etc/p620-fans.conf
#   echo 2 | sudo tee /sys/class/hwmon/hwmon*/pwm[14567]_enable   # back to firmware control
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
command -v nvidia-smi >/dev/null || echo "!! nvidia-smi not found: GPU fans will run at 100% (NO TEMP) until the NVIDIA driver is installed"
grep -qx nct6686 /sys/class/hwmon/hwmon*/name 2>/dev/null || { echo "!! nct6686 hwmon device missing: install the driver (1-driver) and reboot first"; exit 1; }
cd "$(dirname "$0")"

if systemctl list-unit-files p620-gpu-fans.service >/dev/null 2>&1 && [ -e /etc/systemd/system/p620-gpu-fans.service ]; then
  echo "== replacing p620-gpu-fans"
  systemctl disable --now p620-gpu-fans || true
  [ -e /etc/p620-gpu-fans.conf ] && mv /etc/p620-gpu-fans.conf /etc/p620-gpu-fans.conf.old
  rm -f /etc/systemd/system/p620-gpu-fans.service /usr/local/sbin/p620-gpu-fans
fi

install -m 0755 p620-fans.py /usr/local/sbin/p620-fans
if [ -e /etc/p620-fans.conf ] && ! cmp -s p620-fans.conf /etc/p620-fans.conf; then
  cp /etc/p620-fans.conf "/etc/p620-fans.conf.bak.$(date +%s)"; echo "existing /etc/p620-fans.conf backed up"
fi
install -m 0644 p620-fans.conf /etc/p620-fans.conf
install -m 0644 p620-fans.service /etc/systemd/system/p620-fans.service
systemctl daemon-reload
systemctl enable p620-fans
systemctl restart p620-fans      # restart, not "enable --now": that leaves an already-running old version in place
sleep 4
systemctl --no-pager --lines=8 -l status p620-fans
