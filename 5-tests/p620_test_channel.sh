#!/usr/bin/env bash
# Slow on/off test of ONE PWM channel on the P620, to find fans without a speed sensor.
# Run: sudo bash p620_test_channel.sh [channel]   (default 4)
# Alternates STOP (0%) and FULL (100%) every 5 s until you press Enter, or for at most 2 minutes.
# The channel is restored to its original mode/duty afterwards, and on Ctrl-C.
set -u
CH=${1:-4}
PHASE=${2:-5}   # seconds per STOP / FULL phase
H=""
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6686 ] && H=$h; done
[ -z "$H" ] && { echo "nct6686 hwmon device not found"; exit 1; }
[ -e $H/pwm$CH ] || { echo "pwm$CH does not exist"; exit 1; }

EN0=$(cat $H/pwm${CH}_enable); DU0=$(cat $H/pwm$CH)
LOOP=""
cleanup() {
  [ -n "$LOOP" ] && kill $LOOP 2>/dev/null
  if [ "$EN0" = 1 ]; then echo 1 > $H/pwm${CH}_enable; echo $DU0 > $H/pwm$CH; else echo 2 > $H/pwm${CH}_enable; fi
  echo; echo "pwm$CH restored (enable=$EN0)."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

gpus() { command -v nvidia-smi >/dev/null && \
  nvidia-smi --query-gpu=pci.bus_id,name,temperature.gpu --format=csv,noheader 2>/dev/null | \
  awk -F', ' '/P100/ {split($1,a,":"); printf "  P100@%s:%s°C", a[2], $3}'; }
rpms() { for f in 1 2 3 4 5 6 7 8; do printf "%6s" "$(cat $H/fan${f}_input 2>/dev/null || echo -)"; done; gpus; }

echo "pwm$CH was enable=$EN0 duty=$DU0. Starting: $PHASE s STOP / $PHASE s FULL."
echo "Watch every fan in the case (and the back of the PSU / rear grille). Press Enter to finish."
echo "              fan1  fan2  fan3  fan4  fan5  fan6  fan7  fan8"
echo 1 > $H/pwm${CH}_enable
(
  end=$((SECONDS + 120))
  while [ $SECONDS -lt $end ]; do
    echo 0 > $H/pwm$CH;   sleep $((PHASE - 1)); echo "  STOP  (0%): $(rpms)"; sleep 1
    echo 255 > $H/pwm$CH; sleep $((PHASE - 1)); echo "  FULL(100%): $(rpms)"; sleep 1
  done
  echo "  2-minute limit reached — press Enter."
) &
LOOP=$!
read -r _
