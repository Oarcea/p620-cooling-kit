#!/usr/bin/env bash
# CPU stress (all 64 threads, AVX2 FMA) with logging of temps, package power, clocks and fans.
# Runs as a normal user; fans are left to whatever controls them (firmware auto by default).
# Usage: bash cpu_stress_log.sh [seconds=600] [guard_tctl=92] [log_name=cpu_stress_auto]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/../p620_diag"
DUR=${1:-600}; GUARD=${2:-92}; NAME=${3:-cpu_stress_auto}
LOG="$HERE/../p620_diag/$NAME.csv"
export LC_ALL=C
H=$(grep -l nct6686 /sys/class/hwmon/hwmon*/name | xargs dirname)
K=$(grep -l k10temp /sys/class/hwmon/hwmon*/name | xargs dirname)
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
WRAP=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj)

"$HERE/cpu_burn" "$DUR" > "$HERE/../p620_diag/$NAME.burn.txt" 2>&1 &
LOAD=$!
trap 'kill $LOAD 2>/dev/null' EXIT

tctl()  { echo $(( $(cat $K/temp1_input) / 1000 )); }
tccd()  { local m=0 v; for f in $K/temp[3-9]_input $K/temp1[0-9]_input; do [ -e $f ] || continue; v=$(( $(cat $f) / 1000 )); [ $v -gt $m ] && m=$v; done; echo $m; }
mhz()   { awk '{s+=$1; n++} END {printf "%.0f", s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; }
duty()  { echo $(( $(cat $H/pwm$1) * 100 / 255 )); }

echo "t_s,phase,tctl,tccd_max,pkg_W,avg_MHz,pwm1_enable,pwm1_duty,fan1_rpm,fan2_rpm,fan5_rear_rpm,pwm5_duty,fan3_psu_rpm" > "$LOG"
start=$SECONDS; e0=$(cat $RAPL); t0=$(date +%s.%N); phase=load
while :; do
  sleep 5
  e1=$(cat $RAPL); t1=$(date +%s.%N)
  w=$(awk -v a=$e0 -v b=$e1 -v x=$t0 -v y=$t1 -v m=$WRAP 'BEGIN { d=b-a; if (d<0) d+=m; printf "%.0f", d/1e6/(y-x) }')
  e0=$e1; t0=$t1; t=$((SECONDS - start)); tc=$(tctl)
  echo "$t,$phase,$tc,$(tccd),$w,$(mhz),$(cat $H/pwm1_enable),$(duty 1),$(cat $H/fan1_input),$(cat $H/fan2_input),$(cat $H/fan5_input),$(duty 5),$(cat $H/fan3_input)" >> "$LOG"
  if [ $phase = load ]; then
    if [ $tc -ge $GUARD ]; then echo "GUARD: Tctl $tc °C at t=${t}s — load stopped" >> "$LOG"; kill $LOAD 2>/dev/null; phase=cool; cs=$t; continue; fi
    kill -0 $LOAD 2>/dev/null || { phase=cool; cs=$t; }
  elif [ $((t - cs)) -ge 120 ]; then
    break
  fi
done
echo "DONE" >> "$LOG"
