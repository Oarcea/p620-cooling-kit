#!/usr/bin/env bash
# Quick test: BOTH 40 mm fans (DIMM1 + DIMM2) mounted on ONE P100 (the top card), full 250 W load on that card only.
# Run: sudo bash p620_twofan_test.sh [load_seconds=300] [top_card 1|2 — optional, auto-detected otherwise]
#  1. stops the p620-fans service (it would drive one fan from the other, idle card)
#  2. both fans 100% for 30 s, no load -> the card that cools down is the one with the fans
#  3. full FP16 load on that card only, logging every 5 s
#  4. guards: loaded card >= 80 °C, or the fan-less card >= 72 °C -> stop
#  5. 60 s cooldown at 100%, then the service is restarted
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
DUR=${1:-300}
TOP_ARG=${2:-}      # optional: 1 or 2 to skip auto-detection of the card with the fans
case "$TOP_ARG" in ""|1|2) ;; *) echo "2nd argument must be 1 or 2"; exit 1;; esac
LOG="$HERE/p620_diag/twofan_test.log"
PY=${PY:-/home/p620/env_isaaclab/bin/python}   # any Python with CUDA PyTorch; override: PY=/path/to/python bash ...
USER_NAME="${SUDO_USER:-p620}"
declare -A UUID=([1]=GPU-5bb70be1-f1d0-4c22-c42f-064d81590f4d [2]=GPU-0bb243e3-ae6e-e054-68fc-cc5845ded711)
export LC_ALL=C
exec > >(tee "$LOG") 2>&1

H=$(grep -l nct6686 /sys/class/hwmon/hwmon*/name | xargs dirname)
temp()  { nvidia-smi -i "${UUID[$1]}" --query-gpu=temperature.gpu --format=csv,noheader,nounits | tr -d ' '; }
row()   { nvidia-smi -i "${UUID[$1]}" --query-gpu=temperature.gpu,power.draw,clocks.sm,clocks_throttle_reasons.active --format=csv,noheader,nounits | tr -d ' '; }
fans()  { echo 1 > $H/pwm6_enable; echo 1 > $H/pwm7_enable; echo $1 > $H/pwm6; echo $1 > $H/pwm7; }

LOAD=""
cleanup() {
  [ -n "$LOAD" ] && kill "$LOAD" 2>/dev/null
  pkill -u "$USER_NAME" -f "gpu_burn.py fp16" 2>/dev/null
  echo; echo "[cooldown] load stopped, both fans 100% for 60 s"
  fans 255
  for i in 1 2 3 4; do sleep 15; echo "  +$((i*15))s  P100-1 $(temp 1)°C  P100-2 $(temp 2)°C"; done
  systemctl start p620-fans && echo "[restore] p620-fans service restarted"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

systemctl stop p620-fans && echo "p620-fans stopped for the test"
fans 255
a1=$(temp 1); a2=$(temp 2)
echo "Identifying the card with the fans: both fans 100%, no load, 30 s ..."
sleep 30
b1=$(temp 1); b2=$(temp 2)
d1=$((a1 - b1)); d2=$((a2 - b2))
echo "  P100-1: $a1 -> $b1 °C (drop $d1)   P100-2: $a2 -> $b2 °C (drop $d2)"
TOP=""
if [ -n "$TOP_ARG" ]; then TOP=$TOP_ARG; echo "  (card given on the command line: P100-$TOP)"
elif [ $d1 -ge $((d2 + 2)) ]; then TOP=1
elif [ $d2 -ge $((d1 + 2)) ]; then TOP=2
else
  echo "!! Could not tell which card has the fans (drops $d1 vs $d2 °C)."
  echo "   Re-run with the card number as 2nd argument:  sudo bash $0 $DUR 1   (or 2)"
  exit 1
fi
OTHER=$((3 - TOP))
echo "=> top card with both fans: P100-$TOP (${UUID[$TOP]}); P100-$OTHER has no fan and stays idle"
echo

sudo -u "$USER_NAME" env CUDA_VISIBLE_DEVICES="${UUID[$TOP]}" "$PY" -I -W ignore "$HERE/gpu_burn.py" fp16 "$DUR" >/dev/null 2>&1 &
LOAD=$!
echo "  t_s | P100-$TOP temp  W    MHz  throttle            | fan6  fan7 rpm   | P100-$OTHER (no fan) temp"
start=$SECONDS
while kill -0 "$LOAD" 2>/dev/null; do
  sleep 5; t=$((SECONDS - start))
  IFS=, read -r tt tw tm tr <<< "$(row $TOP)"; to=$(temp $OTHER)
  printf "  %3s | %3s°C %6.1f %4s %s | %5s %5s | %3s°C\n" $t $tt $tw $tm $tr $(cat $H/fan6_input) $(cat $H/fan7_input) $to
  echo "$t,$tt,$tw,$tm,$tr,$to" >> "$HERE/p620_diag/twofan_test.csv"
  [ "$tt" -ge 80 ] && { echo "GUARD: loaded card reached 80 °C — stopping"; break; }
  [ "$to" -ge 72 ] && { echo "GUARD: fan-less card reached 72 °C — stopping"; break; }
done
echo
awk -F, -v s=$((DUR - 120)) '$1>=s {n++; t+=$2; w+=$3; m+=$4} END {if (n) printf "STEADY (last 2 min, %d samples): %.1f °C  %.0f W  %.0f MHz\n", n, t/n, w/n, m/n}' "$HERE/p620_diag/twofan_test.csv"
echo "one-fan reference (10-min test): P100-1 78.9 °C 226 W 1254 MHz | P100-2 78.9 °C 215 W 1218 MHz"
