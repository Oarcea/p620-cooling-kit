#!/usr/bin/env bash
# Long full-TDP stress of both P100s (FP16 cuBLAS GEMM on random data ≈ 250 W each).
# Fans are left to the p620-fans service. Runs as a normal user.
# Usage: bash p620_stress_long.sh [seconds=600] [guard_temp=80]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
DUR=${1:-600}; GUARD=${2:-80}
LOG="$HERE/p620_diag/stress_long.csv"
PY=${PY:-/home/p620/env_isaaclab/bin/python}   # any Python with CUDA PyTorch; override: PY=/path/to/python bash ...
U1=GPU-5bb70be1-f1d0-4c22-c42f-064d81590f4d; U2=GPU-0bb243e3-ae6e-e054-68fc-cc5845ded711
H=$(grep -l nct6686 /sys/class/hwmon/hwmon*/name | xargs dirname)
export LC_ALL=C

PIDS=()
stop_load() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap stop_load EXIT

for U in $U1 $U2; do
  CUDA_VISIBLE_DEVICES=$U "$PY" -I -W ignore "$HERE/gpu_burn.py" fp16 "$DUR" >/dev/null 2>&1 &
  PIDS+=($!)
done

q() { nvidia-smi -i "$1" --query-gpu=temperature.gpu,power.draw,clocks.sm,clocks_throttle_reasons.active --format=csv,noheader,nounits | tr -d ' '; }
echo "t_s,p1_temp,p1_W,p1_MHz,p1_throttle,fan6_duty,fan6_rpm,p2_temp,p2_W,p2_MHz,p2_throttle,fan7_duty,fan7_rpm,cpu_tctl" > "$LOG"
start=$SECONDS
while :; do
  t=$((SECONDS - start))
  r1=$(q $U1); r2=$(q $U2)
  d6=$(( $(cat $H/pwm6) * 100 / 255 )); d7=$(( $(cat $H/pwm7) * 100 / 255 ))
  tc=$(( $(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -1) / 1000 ))
  for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = k10temp ] && tc=$(( $(cat $h/temp1_input) / 1000 )); done
  echo "$t,$r1,$d6,$(cat $H/fan6_input),$r2,$d7,$(cat $H/fan7_input),$tc" >> "$LOG"
  t1=${r1%%,*}; t2=${r2%%,*}
  if [ "$t1" -ge "$GUARD" ] || [ "$t2" -ge "$GUARD" ]; then
    echo "GUARD: $GUARD °C reached at t=${t}s (P100-1 $t1, P100-2 $t2) — load stopped" | tee -a "$LOG"; break
  fi
  alive=0; for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ $alive -eq 0 ] && break
  [ $t -ge $((DUR + 5)) ] && break
  sleep 5
done
stop_load
# 2 minutes of cooldown logging
for i in $(seq 1 24); do
  sleep 5; t=$((SECONDS - start)); r1=$(q $U1); r2=$(q $U2)
  echo "$t,$r1,$(( $(cat $H/pwm6) * 100 / 255 )),$(cat $H/fan6_input),$r2,$(( $(cat $H/pwm7) * 100 / 255 )),$(cat $H/fan7_input),cool" >> "$LOG"
done
echo "DONE" >> "$LOG"
