#!/usr/bin/env python3
"""ThinkStation P620 NCT6686D EC probe: dump fans/PWM/temps, then test manual PWM write.
Run: sudo python3 -I p620_ec_probe.py [--no-write]
Write test only RAISES fan speed, 5 s per fan, and always restores auto mode."""
import os, sys, time, atexit

BASE = 0xA24          # EC port 1 (HWM base 0xA20 + 4), same as Linux nct6683 and ACPI ECSR/ECSW
PAGE, INDEX, DATA = BASE, BASE + 1, BASE + 2
fd = os.open("/dev/port", os.O_RDWR)

def outb(p, v): os.lseek(fd, p, 0); os.write(fd, bytes([v & 0xFF]))
def inb(p): os.lseek(fd, p, 0); return os.read(fd, 1)[0]

def _lock(page):
    for _ in range(50):
        if inb(PAGE) == 0xFF: break
        time.sleep(0.002)
    else:
        outb(PAGE, 0xFF)
    outb(PAGE, page)

def rd(reg):
    _lock(reg >> 8); outb(INDEX, reg & 0xFF); v = inb(DATA); outb(PAGE, 0xFF); return v

def wr(reg, val):
    _lock(reg >> 8); outb(INDEX, reg & 0xFF); outb(DATA, val); outb(PAGE, 0xFF)

def rd16(reg): return (rd(reg) << 8) | rd(reg + 1)

def fans():
    return [rd16(0x140 + 2 * i) for i in range(16)]

def pwms():
    return [rd(0x160 + i) for i in range(8)]

print("== Identity")
print(f"customer id 0x602 = {rd16(0x602):#06x}")
print(f"firmware build 20{rd(0x604):02d}-{rd(0x605):02d}-{rd(0x606):02d} serial {rd(0x607):#04x} ver {rd(0x608):#04x}.{rd(0x609):02x}")

print("\n== Fan inputs (RPM) and fanin cfg 0x260+x (bit7=enabled)")
f = fans()
for i, r in enumerate(f):
    cfg = rd(0x260 + i)
    if r or cfg: print(f"fan{i+1}: {r:5d} RPM   cfg={cfg:#04x}")

print("\n== PWM outputs: duty 0x160+x, fanout cfg 0x290+x")
p = pwms()
for i, v in enumerate(p):
    print(f"pwm{i+1}: {v:3d}/255 ({v*100//255:3d}%)   out_cfg={rd(0x290 + i):#04x}")

print("\n== Temperature/monitor channels (cfg 0x1a0+x != 0)")
for i in range(32):
    cfg = rd(0x1A0 + i)
    if cfg:
        raw = rd16(0x100 + 2 * i)
        t = (raw >> 7) / 2 if raw < 0x8000 else -((0x10000 - raw) >> 7) / 2
        print(f"mon{i:2d}: src={cfg:#04x} raw={raw:#06x} ~{t:.1f}°C")

print("\n== Manual-control registers (nct6687-style)")
mode0, cmd0 = rd(0xA00), rd(0xA01)
print(f"0xA00 fan ctrl mode = {mode0:#04x}  0xA01 cmd = {cmd0:#04x}  0xA28.. = {[rd(0xA28+i) for i in range(8)]}")

print("\n== Raw page dumps for reference")
for page in (0x01, 0x02, 0x0A):
    print(f"-- page {page:#04x}")
    for row in range(0, 256, 16):
        print(f"{page:02x}{row:02x}: " + " ".join(f"{rd((page << 8) | (row + c)):02x}" for c in range(16)))

if "--no-write" in sys.argv:
    sys.exit(0)

def restore():
    wr(0xA00, mode0); wr(0xA01, 0x80); time.sleep(0.05); wr(0xA01, 0x40)
    print(f"[restore] 0xA00 back to {mode0:#04x}, auto control restored")
atexit.register(restore)

def set_manual(idx, duty):
    m = rd(0xA00) | (1 << idx)
    wr(0xA00, m); wr(0xA01, 0x80); time.sleep(0.05)
    wr(0xA28 + idx, duty); wr(0xA01, 0x40); time.sleep(0.05)

print("\n== PWM write test (raise only, 5 s each)")
base_f = fans()
for idx in range(8):
    cur = rd(0x160 + idx)
    if cur >= 245:
        print(f"pwm{idx+1}: already ~100%, skip"); continue
    target = 255
    set_manual(idx, target)
    time.sleep(5)
    after_p, after_f = rd(0x160 + idx), fans()
    changed = [f"fan{i+1} {base_f[i]}->{after_f[i]}" for i in range(16) if abs(after_f[i] - base_f[i]) > max(150, base_f[i] * 0.15)]
    print(f"pwm{idx+1}: duty {cur}->{after_p} (asked {target}); RPM changes: {changed or 'none'}")
    restore()
    time.sleep(4)
    base_f = fans()
print("\nDONE")
