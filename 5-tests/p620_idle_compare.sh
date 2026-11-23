#!/usr/bin/env bash
# Idle logger for comparing fan control modes: every 5 s, CPU temps + CPU/rear/front duty, rpm and mode.
# mode column: 1 = manual (p620-fans), 2 = firmware auto. Stop: touch p620_diag/idle_compare.stop
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$HERE/p620_diag"
export LC_ALL=C
OUT="$HERE/p620_diag/idle_compare.csv"; STOP="$HERE/p620_diag/idle_compare.stop"; rm -f "$STOP"
H=$(grep -l nct6686 /sys/class/hwmon/hwmon*/name | xargs dirname)
K=$(grep -l k10temp /sys/class/hwmon/hwmon*/name | xargs dirname)
RAPL=/sys/class/powercap/intel-rapl:0; WRAP=$(cat $RAPL/max_energy_range_uj)
echo "time,t_s,cpu_mode,tctl,cpu_W,load1,cpu_duty,cpu_fanA,cpu_fanB,rear_mode,rear_duty,rear_rpm,front_mode,front_duty,front_rpm,psu_rpm,vrm" > "$OUT"
start=$SECONDS; e0=$(cat $RAPL/energy_uj); t0=$(date +%s.%N)
while [ ! -e "$STOP" ] && [ $((SECONDS-start)) -lt 7200 ]; do
  sleep 5
  e1=$(cat $RAPL/energy_uj); t1=$(date +%s.%N)
  w=$(awk -v a=$e0 -v b=$e1 -v x=$t0 -v y=$t1 -v m=$WRAP 'BEGIN{d=b-a; if(d<0)d+=m; printf "%.0f", d/1e6/(y-x)}'); e0=$e1; t0=$t1
  d() { echo $(( $(cat $H/pwm$1) * 100 / 255 )); }
  echo "$(date +%T),$((SECONDS-start)),$(cat $H/pwm1_enable),$(( $(cat $K/temp1_input)/1000 )),$w,$(cut -d' ' -f1 /proc/loadavg),$(d 1),$(cat $H/fan1_input),$(cat $H/fan2_input),$(cat $H/pwm5_enable),$(d 5),$(cat $H/fan5_input),$(cat $H/pwm4_enable),$(d 4),$(cat $H/fan4_input),$(cat $H/fan3_input),$(( $(cat $H/temp3_input)/1000 ))" >> "$OUT"
done
