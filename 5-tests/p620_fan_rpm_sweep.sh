#!/usr/bin/env bash
# Measure rpm vs duty on the P100 shroud fan headers (DIMM1 = pwm6, DIMM2 = pwm7), to choose max_duty
# in /etc/p620-fans.conf for an rpm ceiling. GPUs are not loaded; p620-fans is paused for about 2 min
# and restarted at the end (also on Ctrl-C / error).
# Run: sudo bash p620_fan_rpm_sweep.sh [duty% ...]      (default: 70 75 80 85 88 90 92 95 100)
# Tach note: with a Y-splitter only one fan of each pair reports, and single reads of about half the
# real speed are splitter glitches, so each step reports the median of 6 reads.
set -u
DUTIES=("$@"); [ ${#DUTIES[@]} -gt 0 ] || DUTIES=(70 75 80 85 88 90 92 95 100)
HERE="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$HERE/p620_diag"
LOG="$HERE/p620_diag/fan_rpm_sweep.csv"
export LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
H=""; for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6686 ] && H=$h; done
[ -n "$H" ] || { echo "nct6686 hwmon not found"; exit 1; }

SVC=0; systemctl is-active --quiet p620-fans && SVC=1
restore() {
  if [ $SVC = 1 ]; then systemctl start p620-fans && echo "[restore] p620-fans restarted"
  else echo 2 > $H/pwm6_enable; echo 2 > $H/pwm7_enable; echo "[restore] pwm6/pwm7 back to firmware auto"; fi
}
trap restore EXIT; trap 'exit 130' INT TERM
[ $SVC = 1 ] && systemctl stop p620-fans && echo "p620-fans paused"
echo 1 > $H/pwm6_enable; echo 1 > $H/pwm7_enable

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2) ? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)}'; }
echo "duty_pct,pwm_raw,fan6_rpm,fan7_rpm" | tee "$LOG"
for d in "${DUTIES[@]}"; do
  raw=$(( (d * 255 + 50) / 100 )); echo $raw > $H/pwm6; echo $raw > $H/pwm7
  sleep 6                                    # let the 40 mm fans settle
  r6=(); r7=()
  for i in 1 2 3 4 5 6; do r6+=($(cat $H/fan6_input)); r7+=($(cat $H/fan7_input)); sleep 1; done
  m6=$(printf '%s\n' "${r6[@]}" | median); m7=$(printf '%s\n' "${r7[@]}" | median)
  echo "$d,$raw,$m6,$m7" | tee -a "$LOG"
done
