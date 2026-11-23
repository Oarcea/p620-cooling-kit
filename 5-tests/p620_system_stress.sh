#!/usr/bin/env bash
# Whole-system stress: CPU (AVX2 FMA, 60 threads) + both P100s (FP16 GEMM, ~250 W each).
# Fans stay under the p620-fans service. Runs as a normal user.
# Usage: bash p620_system_stress.sh [seconds=600] [cpu_guard=92] [gpu_guard=84]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
DUR=${1:-600}; CPU_GUARD=${2:-92}; GPU_GUARD=${3:-84}
LOG="$HERE/p620_diag/system_stress.csv"
PY=${PY:-/home/p620/env_isaaclab/bin/python}   # any Python with CUDA PyTorch; override: PY=/path/to/python bash ...
# CPU_BURN=/path/to/cpu_burn overrides the load binary (needed when the kit sits on a FAT stick, which has no exec bit)
U1=GPU-5bb70be1-f1d0-4c22-c42f-064d81590f4d; U2=GPU-0bb243e3-ae6e-e054-68fc-cc5845ded711
export LC_ALL=C
H=$(grep -l nct6686 /sys/class/hwmon/hwmon*/name | xargs dirname)
K=$(grep -l k10temp /sys/class/hwmon/hwmon*/name | xargs dirname)
RAPL=/sys/class/powercap/intel-rapl:0
N=$(grep -l nvme /sys/class/hwmon/hwmon*/name | head -1 | xargs dirname)
U3=GPU-500e4d34-fa94-57e7-72e4-bb0e16f5de88   # Quadro K2200 (display, no load)
TH=()   # last 3 Tctl samples (15 s), roughly what the fan controller averages
WRAP=$(cat $RAPL/max_energy_range_uj)

PIDS=()
stop_load() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; PIDS=(); }
trap stop_load EXIT

"${CPU_BURN:-$HERE/cpu/cpu_burn}" "$DUR" 60 > "$HERE/p620_diag/system_stress.cpu.txt" 2>&1 & PIDS+=($!)
for U in $U1 $U2; do
  CUDA_VISIBLE_DEVICES=$U "$PY" -I -W ignore "$HERE/gpu_burn.py" fp16 "$DUR" >/dev/null 2>&1 & PIDS+=($!)
done

g()    { nvidia-smi -i "$1" --query-gpu=temperature.gpu,power.draw,clocks.sm,clocks_throttle_reasons.active --format=csv,noheader,nounits | tr -d ' '; }
duty() { echo $(( $(cat $H/pwm$1) * 100 / 255 )); }
rpm()  { cat $H/fan$1_input; }
c()    { echo $(( $(cat $1) / 1000 )); }
ccdmax() { m=0; for f in $K/temp[3-9]_input $K/temp1[0-9]_input; do [ -e $f ] && v=$(cat $f) && [ $v -gt $m ] && m=$v; done; echo $((m/1000)); }
mhz()  { awk '{s+=$1; n++} END {printf "%.0f", s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; }

echo "t_s,phase,tctl,tctl_avg15,ccd_max,cpu_W,cpu_MHz,cpu_fan_duty,cpu_fanA,cpu_fanB,rear_duty,rear_rpm,front_duty,front_rpm,psu_rpm,p1_temp,p1_W,p1_MHz,p1_thr,p1_fan_duty,p1_fan_rpm,p2_temp,p2_W,p2_MHz,p2_thr,p2_fan_duty,p2_fan_rpm,p4000_temp,vrm,pch,pcie_x1,m2_1,nvme" > "$LOG"
start=$SECONDS; e0=$(cat $RAPL/energy_uj); t0=$(date +%s.%N); phase=load
while :; do
  sleep 5
  e1=$(cat $RAPL/energy_uj); t1=$(date +%s.%N)
  w=$(awk -v a=$e0 -v b=$e1 -v x=$t0 -v y=$t1 -v m=$WRAP 'BEGIN { d=b-a; if (d<0) d+=m; printf "%.0f", d/1e6/(y-x) }')
  e0=$e1; t0=$t1; t=$((SECONDS - start)); tc=$(( $(cat $K/temp1_input) / 1000 ))
  r1=$(g $U1); r2=$(g $U2)
  TH=("${TH[@]: -2}" $tc); av=$(( ($(IFS=+; echo "${TH[*]}")) / ${#TH[@]} ))
  p4=$(nvidia-smi -i $U3 --query-gpu=temperature.gpu --format=csv,noheader,nounits | tr -d " ")
  echo "$t,$phase,$tc,$av,$(ccdmax),$w,$(mhz),$(duty 1),$(rpm 1),$(rpm 2),$(duty 5),$(rpm 5),$(duty 4),$(rpm 4),$(rpm 3),$r1,$(duty 6),$(rpm 6),$r2,$(duty 7),$(rpm 7),$p4,$(c $H/temp3_input),$(c $H/temp4_input),$(c $H/temp6_input),$(c $H/temp7_input),$(c $N/temp1_input)" >> "$LOG"
  if [ $phase = load ]; then
    g1=${r1%%,*}; g2=${r2%%,*}
    if [ $tc -ge $CPU_GUARD ] || [ $g1 -ge $GPU_GUARD ] || [ $g2 -ge $GPU_GUARD ]; then
      echo "GUARD at t=${t}s: Tctl $tc, P100-1 $g1, P100-2 $g2 — load stopped" >> "$LOG"; stop_load; phase=cool; cs=$t; continue
    fi
    alive=0; for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ $alive -eq 0 ] && { phase=cool; cs=$t; }
  elif [ $((t - cs)) -ge 120 ]; then
    break
  fi
done
echo "DONE" >> "$LOG"
