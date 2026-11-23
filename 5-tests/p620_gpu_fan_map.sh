#!/usr/bin/env bash
# Check that each P100 fan header (DIMM1 = pwm6, DIMM2 = pwm7) really cools the card that
# /etc/p620-fans.conf says it does. Run after moving cards between slots or re-plugging fan cables.
# Run: sudo bash p620_gpu_fan_map.sh
#
# The fan service follows each card by GPU UUID, so moving cards between PCIe slots is fine as long
# as each card's fan cable stays on the same header. This test catches swapped cables.
#
# Steps (both P100s under a moderate cuBLAS load the whole time, about 130 W each):
#   p620-fans is stopped for the test and restarted at the end (also on Ctrl-C / error)
#   warm-up 30 s : pwm6 100 %, pwm7 100 %
#   A       60 s : pwm6 100 %, pwm7   0 % (fan floor about 1,300 rpm)
#   B       60 s : pwm6   0 %, pwm7 100 %
#   cooldown 30 s at 100 %, then the service takes over again
# Safety: any P100 >= 83 °C -> both fans 100 %, load stopped.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
LOG="$HERE/p620_diag/gpu_fan_map.log"
PY=${PY:-/home/p620/env_isaaclab/bin/python}   # any Python with CUDA PyTorch; override: PY=/path/to/python bash ...
CONF=${CONF:-/etc/p620-fans.conf}
USER_NAME="${SUDO_USER:-p620}"
LIMIT=83
export LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
exec > >(tee "$LOG") 2>&1

H=""
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6686 ] && H=$h; done
[ -z "$H" ] && { echo "nct6686 hwmon not found"; exit 1; }

# Which card does the config assign to pwm6 / pwm7?  (section with "pwm = N" and gpu_uuids)
conf_uuid() {  # $1 = pwm number -> UUID and section name
  awk -v want="$1" '
    /^\[/ {sec=$0; pwm=""; uu=""}
    /^[ \t]*pwm[ \t]*=/ {split($0,a,"="); gsub(/[ \t]/,"",a[2]); pwm=a[2]}
    /^[ \t]*gpu_uuids?[ \t]*=/ {split($0,a,"="); gsub(/[ \t]/,"",a[2]); split(a[2],b,","); uu=b[1]}
    pwm==want && uu!="" {gsub(/[\[\]]|fan:/,"",sec); print uu, sec; exit}' "$CONF"
}
read -r UUID6 NAME6 < <(conf_uuid 6)
read -r UUID7 NAME7 < <(conf_uuid 7)
[ -n "${UUID6:-}" ] && [ -n "${UUID7:-}" ] || { echo "could not read pwm6/pwm7 GPU UUIDs from $CONF"; exit 1; }
for U in "$UUID6" "$UUID7"; do
  nvidia-smi -i "$U" --query-gpu=name --format=csv,noheader >/dev/null 2>&1 || { echo "GPU $U from $CONF is not present (card replaced?):"; nvidia-smi -L; exit 1; }
done
bus()  { nvidia-smi -i "$1" --query-gpu=pci.bus_id --format=csv,noheader | sed 's/^00000000://'; }
slot() { lspci -vv -s "$1" 2>/dev/null | awk -F': ' '/Physical Slot/ {print $2}'; }
B6=$(bus $UUID6); B7=$(bus $UUID7)
echo "Config: DIMM1/pwm6 -> $NAME6 ($UUID6) now at PCI $B6, slot $(slot $B6)"
echo "        DIMM2/pwm7 -> $NAME7 ($UUID7) now at PCI $B7, slot $(slot $B7)"

LOADS=(); SVC=0
systemctl is-active --quiet p620-fans && SVC=1
cleanup() {
  for p in "${LOADS[@]}"; do kill "$p" 2>/dev/null; done
  pkill -u "$USER_NAME" -f p620_gpu_burn_marker 2>/dev/null
  echo "[cooldown] load stopped, both fans 100% for 30 s"; setfans 255 255; sleep 30
  if [ $SVC = 1 ]; then systemctl start p620-fans && echo "[restore] p620-fans restarted"
  else echo 2 > $H/pwm6_enable; echo 2 > $H/pwm7_enable; echo "[restore] pwm6/pwm7 back to firmware auto"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
[ $SVC = 1 ] && systemctl stop p620-fans && echo "p620-fans stopped for the test"

setfans() { echo 1 > $H/pwm6_enable; echo 1 > $H/pwm7_enable; echo $1 > $H/pwm6; echo $2 > $H/pwm7; }
temp()  { nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader -i "$1"; }
power() { nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits -i "$1" | cut -d. -f1; }

burn() {  # $1 = GPU UUID — moderate load (uninitialised matrices, about 130 W)
  sudo -u "$USER_NAME" env CUDA_VISIBLE_DEVICES="$1" "$PY" -I -W ignore -c "
import torch, sys  # p620_gpu_burn_marker
d=torch.device('cuda:0'); a=torch.empty(8192,8192,device=d); b=torch.empty(8192,8192,device=d)
while True:
    c=torch.mm(a,b); torch.cuda.synchronize(d)
" >/dev/null 2>&1 &
  LOADS+=($!)
}

run_phase() {  # name secs pwm6 pwm7
  local name=$1 secs=$2; setfans $3 $4
  echo; echo "== $name: pwm6=$3 pwm7=$4"
  local t=0
  while [ $t -lt $secs ]; do
    sleep 5; t=$((t + 5))
    local t6=$(temp $UUID6) t7=$(temp $UUID7)
    printf "  t=%3ss  %s %3s°C %3sW | %s %3s°C %3sW | fan6 %5s fan7 %5s RPM\n" \
      $t "$NAME6" $t6 $(power $UUID6) "$NAME7" $t7 $(power $UUID7) $(cat $H/fan6_input) $(cat $H/fan7_input)
    if [ "$t6" -ge $LIMIT ] || [ "$t7" -ge $LIMIT ]; then
      setfans 255 255; echo "!! $LIMIT °C reached — fans 100%, stopping test"; exit 2
    fi
  done
  END6=$(temp $UUID6); END7=$(temp $UUID7)
}

burn "$UUID6"; burn "$UUID7"
sleep 3
run_phase "warm-up" 30 255 255
run_phase "A (DIMM1 full, DIMM2 floor)" 60 255 0;  A6=$END6; A7=$END7
run_phase "B (DIMM1 floor, DIMM2 full)" 60 0 255;  B6=$END6; B7=$END7

echo; echo "== Result"
echo "$NAME6: A ${A6}°C  B ${B6}°C   (B - A = $((B6 - A6)))"
echo "$NAME7: A ${A7}°C  B ${B7}°C   (B - A = $((B7 - A7)))"
# Correct wiring: DIMM1 cools NAME6 -> NAME6 hotter in B, NAME7 hotter in A
if [ $((B6 - A6)) -gt 2 ] && [ $((B7 - A7)) -lt -2 ]; then
  echo "MAPPING OK: DIMM1 (pwm6) cools $NAME6, DIMM2 (pwm7) cools $NAME7 — matches $CONF ✔"
elif [ $((B6 - A6)) -lt -2 ] && [ $((B7 - A7)) -gt 2 ]; then
  echo "MAPPING SWAPPED ✘: DIMM1 (pwm6) cools $NAME7, DIMM2 (pwm7) cools $NAME6"
  echo "Fix: swap the two fan cables on DIMM1/DIMM2, OR swap 'pwm = 6' and 'pwm = 7' in $CONF and restart p620-fans"
else
  echo "MAPPING INCONCLUSIVE (differences under 3 °C) — see the log above; are both fans on separate cards?"
fi
