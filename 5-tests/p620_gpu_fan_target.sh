#!/usr/bin/env bash
# Find the shroud-fan duty that holds each P100 at a target temperature under full load,
# with BOTH cards loaded at once (they heat each other). Use the result to shape gpu_curve.
# Run: sudo bash p620_gpu_fan_target.sh [target=75] [seconds=900]
#
# - p620-fans is stopped for the test and restarted at the end (also on Ctrl-C / error)
# - CPU fans 30 %, rear + front 35 % (light-CPU desktop values); 100 % if Tctl >= 75 °C
# - both P100s: FP16 GEMM on random data (gpu_burn.py fp16, ~250 W power cap)
# - every 5 s a PI controller per card adjusts its header's duty towards the target temperature
# - card >= 80 °C -> its fans 100 %;  card >= 83 °C -> load stopped
# - result: average temperature / duty / rpm over the last third of the run, per card
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
TARGET=${1:-75}; DUR=${2:-900}
CSV="$HERE/p620_diag/gpu_fan_target.csv"; LOG="$HERE/p620_diag/gpu_fan_target.log"
PY=${PY:-/home/p620/env_isaaclab/bin/python}
CONF=${CONF:-/etc/p620-fans.conf}
USER_NAME="${SUDO_USER:-p620}"
export LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
exec > >(tee "$LOG") 2>&1

H=$(grep -l nct6686 /sys/class/hwmon/hwmon*/name | xargs dirname)
K=$(grep -l k10temp /sys/class/hwmon/hwmon*/name | xargs dirname)
[ -n "$H" ] && [ -n "$K" ] || { echo "nct6686 / k10temp hwmon not found"; exit 1; }

conf_uuid() {  # $1 = pwm number -> "UUID name" from the [fan:…] section using that header
  awk -v want="$1" '
    /^\[/ {sec=$0; pwm=""; uu=""}
    /^[ \t]*pwm[ \t]*=/ {split($0,a,"="); gsub(/[ \t]/,"",a[2]); pwm=a[2]}
    /^[ \t]*gpu_uuids?[ \t]*=/ {split($0,a,"="); gsub(/[ \t]/,"",a[2]); split(a[2],b,","); uu=b[1]}
    pwm==want && uu!="" {gsub(/[\[\]]|fan:/,"",sec); print uu, sec; exit}' "$CONF"
}
declare -A U N
read -r U[6] N[6] < <(conf_uuid 6)
read -r U[7] N[7] < <(conf_uuid 7)
for p in 6 7; do
  [ -n "${U[$p]:-}" ] || { echo "no GPU for pwm$p in $CONF"; exit 1; }
  nvidia-smi -i "${U[$p]}" --query-gpu=name --format=csv,noheader >/dev/null 2>&1 || { echo "GPU ${U[$p]} not present"; exit 1; }
done
echo "Target ${TARGET} °C for ${DUR} s.  pwm6 -> ${N[6]} (${U[6]}),  pwm7 -> ${N[7]} (${U[7]})"

LOADS=(); SVC=0
systemctl is-active --quiet p620-fans && SVC=1
setpwm() { echo 1 > $H/pwm${1}_enable; echo $(( $2 * 255 / 100 )) > $H/pwm$1; }
cleanup() {
  for p in "${LOADS[@]}"; do kill "$p" 2>/dev/null; done
  pkill -u "$USER_NAME" -f 'gpu_burn.py fp16' 2>/dev/null
  echo "[cooldown] load stopped, P100 fans 100% for 30 s"; setpwm 6 100; setpwm 7 100; sleep 30
  if [ $SVC = 1 ]; then systemctl start p620-fans && echo "[restore] p620-fans restarted"
  else for p in 1 4 5 6 7; do echo 2 > $H/pwm${p}_enable; done; echo "[restore] headers back to firmware auto"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
[ $SVC = 1 ] && systemctl stop p620-fans && echo "p620-fans stopped for the test"

setpwm 1 30; setpwm 4 35; setpwm 5 35
for p in 6 7; do
  sudo -u "$USER_NAME" env CUDA_VISIBLE_DEVICES="${U[$p]}" "$PY" -I -W ignore "$HERE/gpu_burn.py" fp16 $((DUR + 120)) >/dev/null 2>&1 &
  LOADS+=($!)
done

# PI controller in velocity form, every 5 s:  duty += KP*(e - e_prev) + KI*e,  e = T - target
KP=4; KI=0.5
declare -A D E ARMED
for p in 6 7; do D[$p]=30; E[$p]=0; ARMED[$p]=0; setpwm $p 30; done   # 30 % until the card first nears the target
q() { nvidia-smi -i "$1" --query-gpu=temperature.gpu,power.draw,clocks.sm,clocks_throttle_reasons.active --format=csv,noheader,nounits | tr -d ' '; }
echo "t_s,tctl,cpu_duty,p6_card,p6_temp,p6_W,p6_MHz,p6_thr,p6_duty,p6_rpm,p7_card,p7_temp,p7_W,p7_MHz,p7_thr,p7_duty,p7_rpm" > "$CSV"
start=$SECONDS
while [ $((SECONDS - start)) -lt $DUR ]; do
  sleep 5; t=$((SECONDS - start)); line="$t"
  tc=$(( $(cat $K/temp1_input) / 1000 ))
  if [ $tc -ge 75 ]; then setpwm 1 100; setpwm 4 100; setpwm 5 100; fi
  line="$line,$tc,$(( $(cat $H/pwm1) * 100 / 255 ))"
  for p in 6 7; do
    r=$(q "${U[$p]}"); T=${r%%,*}
    if [ "$T" -ge 83 ]; then echo "!! ${N[$p]} reached $T °C — stopping"; exit 2; fi
    e=$((T - TARGET))
    [ ${ARMED[$p]} = 0 ] && [ $e -ge -2 ] && ARMED[$p]=1
    if [ ${ARMED[$p]} = 1 ]; then
      D[$p]=$(awk -v d=${D[$p]} -v e=$e -v ep=${E[$p]} -v kp=$KP -v ki=$KI 'BEGIN{d+=kp*(e-ep)+ki*e; if(d<0)d=0; if(d>100)d=100; printf "%.1f", d}')
    fi
    [ "$T" -ge 80 ] && D[$p]=100
    E[$p]=$e
    setpwm $p ${D[$p]%.*}
    line="$line,${N[$p]},$r,${D[$p]},$(cat $H/fan${p}_input)"
  done
  echo "$line" >> "$CSV"
  [ $((t % 30)) -lt 5 ] && echo "$line" | awk -F, '{printf "t=%4ss Tctl %s | %s %s°C %sW %sMHz duty %5s%% %5srpm | %s %s°C %sW %sMHz duty %5s%% %5srpm\n",$1,$2,$4,$5,$6,$7,$9,$10,$11,$12,$13,$14,$16,$17}'
done

echo; echo "== Result: average over the last third (t >= $((DUR * 2 / 3)) s)"
awk -F, -v from=$((DUR * 2 / 3)) 'NR>1 && $1>=from {n++; t6+=$5; w6+=$6; c6+=$7; d6+=$9; r6+=$10; t7+=$12; w7+=$13; c7+=$14; d7+=$16; r7+=$17; a=$4; b=$11
  if(n==1||$9+0<mn6)mn6=$9+0; if($9+0>mx6)mx6=$9+0; if(n==1||$16+0<mn7)mn7=$16+0; if($16+0>mx7)mx7=$16+0}
  END{ if(!n){print "no data"; exit}
    printf "%-7s %.1f °C  %3.0f W  %4.0f MHz   duty %4.1f %% (range %s–%s)  %5.0f rpm\n", a, t6/n, w6/n, c6/n, d6/n, mn6, mx6, r6/n
    printf "%-7s %.1f °C  %3.0f W  %4.0f MHz   duty %4.1f %% (range %s–%s)  %5.0f rpm\n", b, t7/n, w7/n, c7/n, d7/n, mn7, mx7, r7/n }' "$CSV"
echo "Full log: $CSV"
