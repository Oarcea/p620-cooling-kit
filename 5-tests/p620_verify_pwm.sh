#!/usr/bin/env bash
# Post-reboot check of nct6687 hwmon PWM control on the P620.
# Run: sudo bash p620_verify_pwm.sh   (raises each live channel to 100% for 6 s, then back to auto)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
exec > >(tee "$HERE/p620_diag/verify.log") 2>&1
echo "cmdline: $(grep -o 'acpi_enforce_resources=[a-z]*' /proc/cmdline || echo MISSING)"
echo "module:  $(lsmod | grep -E '^nct66' || echo NOT LOADED)"
dmesg | grep -i -E 'nct66|0xa2[04]' | tail -5
H=""
for h in /sys/class/hwmon/hwmon*; do case $(cat $h/name) in nct66*) H=$h;; esac; done
[ -z "$H" ] && { echo "!! no nct66xx hwmon device"; exit 1; }
echo "hwmon: $H ($(cat $H/name))"; echo
sensors "$(cat $H/name)-isa-0a20" 2>/dev/null || sensors | sed -n '/nct66/,/^$/p'

declare -A SAVED
restore() { for i in "${!SAVED[@]}"; do echo 2 > $H/pwm${i}_enable 2>/dev/null; done; echo "[restore] all tested channels back to auto (pwm_enable=2)"; }
trap restore EXIT

echo; echo "== Write test via hwmon sysfs"
for i in 1 3 5; do
  [ -e $H/pwm$i ] || continue
  f0=$(cat $H/fan${i}_input 2>/dev/null || echo 0); p0=$(cat $H/pwm$i)
  SAVED[$i]=1
  echo 1 > $H/pwm${i}_enable && echo 255 > $H/pwm$i
  sleep 6
  echo "pwm$i: enable=$(cat $H/pwm${i}_enable) duty $p0 -> $(cat $H/pwm$i) | fan$i $f0 -> $(cat $H/fan${i}_input 2>/dev/null) RPM"
  echo 2 > $H/pwm${i}_enable; sleep 4
done
echo; echo "== Hold test: pwm3 manual at 255 for 60 s (does firmware take it back?)"
echo 1 > $H/pwm3_enable; echo 255 > $H/pwm3
for t in 15 30 45 60; do sleep 15; echo "t=${t}s enable=$(cat $H/pwm3_enable) duty=$(cat $H/pwm3) fan3=$(cat $H/fan3_input) RPM"; done
echo DONE
