#!/usr/bin/env bash
# Logs CPU Tctl/CCD temps and CPU/rear fan duty+rpm every 0.5 s; snapshots top processes on spikes.
# Stop: touch p620_diag/cpu_spikes.stop (or kill). Max runtime 3 h.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
export LC_ALL=C
OUT="$HERE/p620_diag/cpu_spikes.csv"; TOP="$HERE/p620_diag/cpu_spikes_top.log"; STOP="$HERE/p620_diag/cpu_spikes.stop"
SPIKE=${1:-62}
rm -f "$STOP"; : > "$TOP"
H=$(grep -l nct6686 /sys/class/hwmon/hwmon*/name | xargs dirname)
K=$(grep -l k10temp /sys/class/hwmon/hwmon*/name | xargs dirname)
echo "t,tctl,ccd_max,cpu_duty,cpu_fanA,cpu_fanB,rear_duty,rear_rpm,load1" > "$OUT"
t0=$(date +%s.%N); last_top=0
while [ ! -e "$STOP" ]; do
  now=$(date +%s.%N); t=$(awk -v a=$t0 -v b=$now 'BEGIN{printf "%.1f", b-a}')
  [ "${t%.*}" -ge 10800 ] && break
  tc=$(cat $K/temp1_input); cm=0
  for f in $K/temp[3-9]_input $K/temp1[0-9]_input; do [ -e "$f" ] && v=$(cat $f) && [ $v -gt $cm ] && cm=$v; done
  echo "$t,$((tc/100))e-1,$((cm/100))e-1,$(( $(cat $H/pwm1)*100/255 )),$(cat $H/fan1_input),$(cat $H/fan2_input),$(( $(cat $H/pwm5)*100/255 )),$(cat $H/fan5_input),$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT"
  ts=${t%.*}
  if [ $((tc/1000)) -ge $SPIKE ] && [ $((ts - last_top)) -ge 5 ]; then
    last_top=$ts
    ( { echo "=== t=${t}s Tctl=$((tc/1000)) $(date +%T)"; top -b -n2 -d0.4 -o %CPU -w 160 | awk '/^top -/{n++} n==2' | sed -n '7,14p'; } >> "$TOP" ) &
  fi
  sleep 0.5
done
echo "STOPPED t=$t" >> "$TOP"
