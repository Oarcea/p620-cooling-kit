#!/usr/bin/env bash
# ThinkStation P620 fan-control diagnostics. Read-only except: installs i2c-tools/acpica-tools,
# and test-loads hwmon modules (nct6683/nct6775) which only read sensor registers.
# Run with: sudo bash p620_fan_diag.sh
set -u
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/p620_diag"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/diag.log"
exec > >(tee "$LOG") 2>&1
s() { echo; echo "=================== $* ==================="; }

s "BIOS fan settings (think_lmi)"
for a in FanControlStepping QuadM2PCIeCardFanControl; do
  p=/sys/class/firmware-attributes/thinklmi/attributes/$a
  echo "$a = $(cat $p/current_value) | possible: $(cat $p/possible_values)"
done
echo "pending_reboot = $(cat /sys/class/firmware-attributes/thinklmi/attributes/pending_reboot/current_value 2>/dev/null)"
ls /sys/class/firmware-attributes/thinklmi/authentication/ 2>/dev/null && \
  for f in /sys/class/firmware-attributes/thinklmi/authentication/*/is_enabled; do echo "$f: $(cat $f)"; done

s "DMI (bios, board, cooling devices type 27, temp probes type 28, OEM 11)"
dmidecode -t 0 -t 2 -t 27 -t 28 -t 11 -t 41

s "Packages"
apt-get install -y i2c-tools acpica-tools >/dev/null 2>&1 && echo "i2c-tools + acpica-tools OK"

s "Super I/O chip ID (raw ports 0x2e / 0x4e)"
python3 - <<'PY'
import os
fd = os.open("/dev/port", os.O_RDWR)
def outb(port, v): os.lseek(fd, port, 0); os.write(fd, bytes([v]))
def inb(port): os.lseek(fd, port, 0); return os.read(fd, 1)[0]
for base in (0x2e, 0x4e):
    for name, enter, exit_ in (("Nuvoton/Winbond", [0x87, 0x87], [0xaa]),
                               ("ITE", [0x87, 0x01, 0x55, 0x55 if base == 0x2e else 0xaa], [0x02]),
                               ("Fintek", [0x87, 0x87], [0xaa])):
        for b in enter: outb(base, b)
        outb(base, 0x20); hi = inb(base + 1)
        outb(base, 0x21); lo = inb(base + 1)
        if name == "ITE":
            outb(base, 0x02); outb(base + 1, 0x02)
        else:
            for b in exit_: outb(base, b)
        if (hi, lo) not in ((0xff, 0xff), (0x00, 0x00)):
            print(f"port {base:#x} via {name} entry: chip ID {hi:02x}{lo:02x}")
            # Logical device 0x0B = HWM on Nuvoton: read its base address
            if name == "Nuvoton/Winbond":
                for b in enter: outb(base, b)
                outb(base, 0x07); outb(base + 1, 0x0b)
                outb(base, 0x30); act = inb(base + 1)
                outb(base, 0x60); a_hi = inb(base + 1)
                outb(base, 0x61); a_lo = inb(base + 1)
                outb(base, 0xaa)
                print(f"   LDN 0x0B (HWM/EC) active={act:#x} base={(a_hi<<8)|a_lo:#06x}")
            break
    else:
        print(f"port {base:#x}: no response")
PY

s "sensors-detect (auto)"
yes "" | sensors-detect --auto 2>&1 | tail -40

s "Try in-kernel drivers"
for m in nct6683 nct6775 it87; do
  before=$(ls /sys/class/hwmon)
  if [ $m = nct6683 ]; then modprobe $m force=1 2>&1; else modprobe $m 2>&1; fi
  echo "$m: $(lsmod | grep -c "^$m ") loaded"
  for h in /sys/class/hwmon/hwmon*; do
    n=$(cat $h/name)
    case $n in nct*|it8*|w83*)
      echo "--- $h ($n)"
      for f in $h/pwm[0-9] $h/pwm[0-9]_enable $h/fan[0-9]_input $h/fan[0-9]_label $h/temp[0-9]*_input $h/temp[0-9]*_label; do
        [ -e $f ] && echo "$(basename $f) = $(cat $f 2>&1)  [$(stat -c %A $f)]"
      done;;
    esac
  done
done
dmesg | grep -i -E 'nct|it87|superio|super i/o|hwmon|ACPI.*(resource|conflict)' | tail -30

s "SMBus scan (PIIX4 buses only)"
modprobe i2c-dev
for b in 0 1 2; do echo "--- i2c-$b"; i2cdetect -y $b; done

s "ACPI tables: fan/thermal objects"
T="$OUT_DIR/acpi"; mkdir -p "$T"; cd "$T"
cp /sys/firmware/acpi/tables/DSDT dsdt.dat
for f in /sys/firmware/acpi/tables/SSDT*; do cp "$f" "$(basename $f | tr A-Z a-z).dat"; done
iasl -d *.dat >/dev/null 2>&1
grep -n -i -E 'PNP0C0B|_FAN|_FST|_FSL|FANS|FAN[0-9]|PWM|SIO1|SIO2|HWM|_TMP|ThermalZone|NCT|0x0A20|0x0290' *.dsl | head -80

s "ACPI WMI descriptors (BMOF) names"
for d in /sys/bus/wmi/devices/*; do echo "$(basename $d): $(cat $d/driver_override 2>/dev/null) $(readlink $d/driver | xargs -r basename)"; done

chown -R "${SUDO_USER:-root}": "$OUT_DIR"
echo; echo "DONE — log at $LOG"
