#!/usr/bin/env bash
# Interactive fan identification for the P620 (nct6686 via nct6687 driver).
# Run: sudo bash p620_identify_fans.sh
# For each PWM channel it pulses the fan 100% <-> 25% every 2 s so you can see/hear which one it is,
# shows which tach (fanN) follows, and asks you to name it. Every channel is restored to its
# original mode/duty afterwards, and on Ctrl-C.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/p620_diag"
OUT="$HERE/p620_diag/fan_map.txt"
H=""
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6686 ] && H=$h; done
[ -z "$H" ] && { echo "nct6686 hwmon device not found"; exit 1; }

declare -A EN DU
for i in 1 2 3 4 5 6 7 8; do EN[$i]=$(cat $H/pwm${i}_enable); DU[$i]=$(cat $H/pwm$i); done
PULSE=""
restore_one() { local i=$1
  if [ "${EN[$i]}" = 1 ]; then echo 1 > $H/pwm${i}_enable; echo ${DU[$i]} > $H/pwm$i
  else echo 2 > $H/pwm${i}_enable; fi; }
cleanup() { [ -n "$PULSE" ] && kill $PULSE 2>/dev/null; for i in 1 2 3 4 5 6 7 8; do restore_one $i; done
  echo; echo "All channels restored to their original state."; }
trap cleanup EXIT
trap 'exit 130' INT TERM

rpms() { for f in 1 2 3 4 5 6 7 8; do printf "%5s " "$(cat $H/fan${f}_input 2>/dev/null || echo -)"; done; }

CHANNELS="${*:-1 2 3 4 5 6 7 8}"
if [ $# -eq 0 ]; then echo "# P620 fan map — $(date)" > "$OUT"
else echo "# retest of pwm channels: $CHANNELS — $(date)" >> "$OUT"; fi
echo "                       fan1  fan2  fan3  fan4  fan5  fan6  fan7  fan8"
echo "baseline RPM:         $(rpms)"
for i in $CHANNELS; do
  echo
  echo "=== pwm$i  (was: enable=${EN[$i]} duty=${DU[$i]}) — pulsing 100% <-> 25% every 2 s ==="
  before=$(rpms)
  echo 1 > $H/pwm${i}_enable
  ( while true; do echo 255 > $H/pwm$i; sleep 2; echo 64 > $H/pwm$i; sleep 2; done ) &
  PULSE=$!
  sleep 1.9; high=$(rpms)
  sleep 2;   low=$(rpms)
  echo "before:               $before"
  echo "at 100%:              $high"
  echo "at 25%:               $low"
  echo "(tach columns that swing between the two rows belong to pwm$i)"
  read -r -p "Which fan is pulsing? (name it, or Enter = nothing visible): " name
  kill $PULSE 2>/dev/null; wait $PULSE 2>/dev/null; PULSE=""
  restore_one $i
  echo "pwm$i = ${name:-<nothing visible>}" | tee -a "$OUT"
  sleep 6   # let fans settle so the next channel's readings are clean
done
echo; echo "Saved to $OUT"
