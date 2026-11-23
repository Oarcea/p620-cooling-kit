#!/usr/bin/env bash
# Step 1: nct6687 kernel driver (DKMS) + boot settings for ThinkStation P620 fan control.
# Run: sudo bash install-driver.sh      then REBOOT.
# Needs: dkms, kernel headers for the running kernel, make, gcc
#   Debian/Ubuntu: sudo apt install dkms linux-headers-$(uname -r) build-essential
#   Fedora:        sudo dnf install dkms kernel-devel-$(uname -r) make gcc
#   Arch:          sudo pacman -S dkms linux-headers base-devel
#   openSUSE:      sudo zypper install dkms kernel-default-devel make gcc
#
# Rollback:
#   sudo dkms remove nct6687d/1 --all && sudo rm -rf /usr/src/nct6687d-1
#   sudo rm /etc/modules-load.d/nct6687.conf /etc/modprobe.d/nct6687.conf
#   and remove acpi_enforce_resources=lax from the kernel command line (see README)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/nct6687d-src"
VER=1
DEST=/usr/src/nct6687d-$VER
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
exec > >(tee "$HERE/install.log") 2>&1

echo "== 1/4 DKMS: copy source, build, install for $(uname -r)"
command -v dkms >/dev/null || { echo "!! dkms not installed (see header of this script)"; exit 1; }
dkms remove nct6687d/$VER --all >/dev/null 2>&1 || true
rm -rf "$DEST"; mkdir -p "$DEST"
cp -a "$SRC"/{nct6687.c,Kbuild,Makefile,dkms.conf} "$DEST"/
dkms add nct6687d/$VER
if ! dkms build nct6687d/$VER -k "$(uname -r)"; then
  echo "!! DKMS build FAILED — nothing else was changed. Last lines of make.log:"
  tail -40 /var/lib/dkms/nct6687d/$VER/build/make.log 2>/dev/null || true
  echo "   Newer kernels may need a newer driver: git clone https://github.com/Fred78290/nct6687d into nct6687d-src"
  exit 1
fi
dkms install nct6687d/$VER -k "$(uname -r)"
dkms status nct6687d

echo "== 2/4 Load nct6687 at boot, keep the stock read-only nct6683 away"
echo nct6687 > /etc/modules-load.d/nct6687.conf
cat > /etc/modprobe.d/nct6687.conf <<'EOT'
# P620 NCT6686D is handled by out-of-tree nct6687; stock nct6683 is read-only here
blacklist nct6683
EOT
modprobe -r nct6683 2>/dev/null || true

echo "== 3/4 Kernel parameter acpi_enforce_resources=lax"
P=acpi_enforce_resources=lax
if grep -qw "$P" /proc/cmdline; then
  echo "already active on the running kernel"
elif command -v update-grub >/dev/null && [ -d /etc/default/grub.d -o -f /etc/default/grub ]; then   # Debian/Ubuntu/Mint
  mkdir -p /etc/default/grub.d
  cat > /etc/default/grub.d/99-nct6687.cfg <<'EOT'
# Allow nct6687 to share the EC I/O ports 0xA24-0xA27 that ACPI declares (ECS1).
# On the P620 the firmware only uses them from an OS-invoked WMI method, so this is safe.
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT acpi_enforce_resources=lax"
EOT
  update-grub
elif command -v kernelstub >/dev/null; then          # Pop!_OS (systemd-boot)
  kernelstub -a "$P"
elif command -v grubby >/dev/null; then              # Fedora / RHEL / Alma / Rocky
  grubby --update-kernel=ALL --args="$P"
elif [ -f /etc/kernel/cmdline ]; then                # systemd-boot + kernel-install / UKI
  grep -qw "$P" /etc/kernel/cmdline || sed -i "1 s/\$/ $P/" /etc/kernel/cmdline
  echo "added to /etc/kernel/cmdline — regenerate boot entries (e.g. 'kernel-install add' / 'mkinitcpio -P' / 'bootctl')"
elif [ -f /etc/default/grub ] && command -v grub-mkconfig >/dev/null; then   # Arch/others with GRUB
  grep -q "$P" /etc/default/grub || sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"/&$P /" /etc/default/grub
  grub-mkconfig -o /boot/grub/grub.cfg
else
  echo "!! Could not detect the bootloader: add '$P' to the kernel command line by hand (see README)."
fi

echo "== 4/4 Done"
modinfo nct6687 | grep -E '^(filename|vermagic)'
echo "Reboot, then:  sudo bash ../5-tests/p620_verify_pwm.sh   (or: sensors nct6686-isa-0a20)"
