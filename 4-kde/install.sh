#!/usr/bin/env bash
# Step 4 (KDE Plasma only): "GPUs & Cooling" System Monitor page + the smooth-CPU-temperature plugin.
# Run as your normal user (NOT sudo): bash install.sh   — it asks for sudo only to copy the plugin.
# Works on Plasma 5 (Qt5) and Plasma 6 (Qt6); the plugin build picks the right one by itself.
#
# Build deps:
#   Debian 13 (Plasma 6):     sudo apt install cmake g++ extra-cmake-modules libksysguard-dev libkf6coreaddons-dev qt6-base-dev
#   Kubuntu 24.04 (Plasma 5): sudo apt install cmake g++ extra-cmake-modules libkf5sysguard-dev libkf5coreaddons-dev qtbase5-dev
#   Fedora (Plasma 6):        sudo dnf install cmake gcc-c++ extra-cmake-modules libksysguard-devel kf6-kcoreaddons-devel qt6-qtbase-devel
#   Arch (Plasma 6):          sudo pacman -S cmake extra-cmake-modules libksysguard kcoreaddons qt6-base
# The page works without the plugin (only the "CPU temperature (16 s average)" line stays empty).
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" != 0 ] || { echo "run as your normal user, not with sudo"; exit 1; }

echo "== page (regenerated at every login, so moving GPUs between slots is picked up automatically)"
install -D -m 0755 make_page.py ~/.local/bin/p620-cooling-page
install -D -m 0644 p620-cooling-page.service ~/.config/systemd/user/p620-cooling-page.service
systemctl --user daemon-reload
systemctl --user enable p620-cooling-page.service
~/.local/bin/p620-cooling-page --install

echo "== plugin build"
B=$(mktemp -d)          # build outside the kit folder (works from a FAT USB stick too)
trap 'rm -rf "$B"' EXIT
if ! { cmake -S ksystemstats-p620 -B "$B" -DCMAKE_BUILD_TYPE=Release && cmake --build "$B"; }; then
  echo "!! plugin build failed (missing build deps? see the top of this script). The page is installed anyway."
  exit 1
fi
QT=$(sed -n 's/^QT_MAJOR_VERSION:[A-Z]*=//p' "$B/CMakeCache.txt"); QT=${QT:-5}
# install next to the stock ksystemstats plugins of the same Qt version, wherever this distro keeps them
CPU_SO=$(find /usr/lib /usr/lib64 -name 'ksystemstats_plugin_cpu.so' -path "*qt${QT}*" 2>/dev/null | head -1)
[ -n "$CPU_SO" ] || CPU_SO=$(find /usr/lib /usr/lib64 -name 'ksystemstats_plugin_cpu.so' 2>/dev/null | head -1)
[ -n "$CPU_SO" ] || { echo "!! ksystemstats plugin folder not found — is plasma-systemmonitor / ksystemstats installed?"; exit 1; }
DIR=$(dirname "$CPU_SO")
echo "== installing Qt${QT} plugin to $DIR (sudo)"
sudo install -m 0644 "$B/ksystemstats_plugin_p620.so" "$DIR/"
systemctl --user restart plasma-ksystemstats 2>/dev/null || systemctl --user restart ksystemstats 2>/dev/null || pkill -x ksystemstats || true
sleep 3
if command -v kstatsviewer >/dev/null; then
  echo "== check (should print a temperature):"
  timeout 6 kstatsviewer p620/cpu/temperatureAverage 2>/dev/null || true
fi
echo "Done. Close and reopen System Monitor, then open the 'GPUs & Cooling' page."
