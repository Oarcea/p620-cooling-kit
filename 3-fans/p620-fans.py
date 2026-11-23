#!/usr/bin/env python3
"""p620-fans: drive ThinkStation P620 fan headers (nct6686) from GPU and CPU temperatures.

Each fan has one or more inputs (CPU Tctl, hottest of a set of GPUs), each with its own curve;
the fan runs at the highest duty any input asks for.
Fail-safes:
  * an input's temperature unreadable -> that fan 100%
  * input at/above its emergency temperature -> that fan 100%
  * max_duty (per fan, default 100) caps every one of these, including the 100% cases
  * firmware takes a channel back out of manual mode -> re-asserted next cycle
  * on stop: fans left at a safe duty (see on_stop) instead of the firmware's curves
Usage: p620-fans [--config FILE] [--dry-run] [--cycles N]
"""
import argparse, configparser, glob, signal, subprocess, time

def log(msg):
    print(msg, flush=True)

def parse_curve(text):
    pts = sorted((float(t), float(d)) for t, d in (p.split(":") for p in text.split()))
    if not pts:
        raise ValueError("empty curve")
    return pts

def interp(curve, temp):
    if temp <= curve[0][0]:
        return curve[0][1]
    for (t0, d0), (t1, d1) in zip(curve, curve[1:]):
        if temp <= t1:
            return d0 + (d1 - d0) * (temp - t0) / (t1 - t0)
    return curve[-1][1]

def find_hwmon(name, wait=60):
    end = time.time() + wait
    while True:
        for d in glob.glob("/sys/class/hwmon/hwmon*"):
            try:
                if open(f"{d}/name").read().strip() == name:
                    return d
            except OSError:
                pass
        if time.time() > end:
            raise SystemExit(f"hwmon '{name}' not found")
        time.sleep(2)

def read_gpu_temps(timeout=5):
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=uuid,temperature.gpu", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=timeout, check=True).stdout
    except (subprocess.SubprocessError, OSError) as e:
        log(f"WARN nvidia-smi failed: {e}")
        return {}
    temps = {}
    for line in out.strip().splitlines():
        try:
            uuid, t = [x.strip() for x in line.split(",")]
            temps[uuid] = float(t)
        except ValueError:
            continue
    return temps

class CpuTemp:
    """Tctl averaged over the last `window` readings: Ryzen Tctl spikes for a second on any burst."""
    def __init__(self, window=3):
        self.window, self.hist = max(1, window), []
        self.path = None
        for d in glob.glob("/sys/class/hwmon/hwmon*"):
            try:
                if open(f"{d}/name").read().strip() == "k10temp":
                    self.path = f"{d}/temp1_input"     # Tctl
            except OSError:
                pass
    def raw(self):
        try:
            return int(open(self.path).read()) / 1000.0
        except (OSError, TypeError, ValueError):
            return None
    def read(self):
        t = self.raw()
        if t is None:
            self.hist.clear()
            return None
        self.hist = (self.hist + [t])[-self.window:]
        return round(sum(self.hist) / len(self.hist), 1)

class Input:
    """One temperature source + curve, with its own hysteresis memory."""
    def __init__(self, kind, curve, uuids=()):
        self.kind, self.curve, self.uuids = kind, curve, list(uuids)
        self.last = None
    def temp(self, gpu_temps, cpu_t):
        if self.kind == "cpu":
            return cpu_t
        vals = [gpu_temps.get(u) for u in self.uuids]
        return None if any(v is None for v in vals) else max(vals)

class Fan:
    def __init__(self, name, sec, hwmon, dry):
        self.name, self.dry = name, dry
        self.pwm = int(sec["pwm"])
        self.min_duty = sec.getfloat("min_duty", 0.0)
        # hard ceiling for this header: applies to curves, EMERGENCY, NO TEMP and on_stop alike
        self.max_duty = max(self.min_duty, min(100.0, sec.getfloat("max_duty", 100.0)))
        self.inputs = []
        if "gpu_curve" in sec or "curve" in sec:          # 'curve'+'gpu_uuid' = old format
            uu = sec.get("gpu_uuids", sec.get("gpu_uuid", ""))
            uuids = [u.strip() for u in uu.split(",") if u.strip()]
            if not uuids:
                raise SystemExit(f"[fan:{name}] gpu curve without gpu_uuids")
            self.inputs.append(Input("gpu", parse_curve(sec.get("gpu_curve", sec.get("curve"))), uuids))
        if "cpu_curve" in sec:
            self.inputs.append(Input("cpu", parse_curve(sec["cpu_curve"])))
        if not self.inputs:
            raise SystemExit(f"[fan:{name}] has no gpu_curve or cpu_curve")
        self.p_duty = f"{hwmon}/pwm{self.pwm}"
        self.p_enable = f"{hwmon}/pwm{self.pwm}_enable"
        self.p_rpm = f"{hwmon}/fan{self.pwm}_input"
        self.duty, self.started, self.status = 100.0, False, ""

    def _w(self, path, val):
        if not self.dry:
            with open(path, "w") as f:
                f.write(str(val))

    def rpm(self):
        try:
            return int(open(self.p_rpm).read())
        except (OSError, ValueError):
            return -1

    def apply(self, duty):
        self.duty = max(0.0, min(self.max_duty, duty))
        try:
            if not self.dry and open(self.p_enable).read().strip() != "1":
                self._w(self.p_enable, 1)
            self._w(self.p_duty, round(self.duty * 255 / 100))
        except OSError as e:
            log(f"ERROR {self.name}: cannot write pwm{self.pwm}: {e}")

    def release(self, mode, hot):
        if mode == "auto":
            self._w(self.p_enable, 2)
            log(f"{self.name}: pwm{self.pwm} handed back to firmware")
        else:
            d = 100 if hot else 50
            self.apply(d)
            log(f"{self.name}: pwm{self.pwm} left at {self.duty:.0f}% (manual)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="/etc/p620-fans.conf")
    ap.add_argument("--dry-run", action="store_true", help="compute and log, never write PWM")
    ap.add_argument("--cycles", type=int, default=0, help="stop after N cycles (testing)")
    a = ap.parse_args()

    cfg = configparser.ConfigParser(inline_comment_prefixes=("#",))
    if not cfg.read(a.config):
        raise SystemExit(f"cannot read {a.config}")
    g = cfg["general"]
    interval = g.getfloat("interval", 2)
    step_down = g.getfloat("step_down", 3)
    hyst = g.getfloat("hysteresis", 2)
    emerg = {"gpu": g.getfloat("gpu_emergency_temp", g.getfloat("emergency_temp", 76)),
             "cpu": g.getfloat("cpu_emergency_temp", 90)}
    on_stop = g.get("on_stop", "safe").strip()

    hwmon = find_hwmon(g.get("hwmon_name", "nct6686"))
    fans = [Fan(s.split(":", 1)[1], cfg[s], hwmon, a.dry_run) for s in cfg.sections() if s.startswith("fan:")]
    if not fans:
        raise SystemExit("no [fan:...] sections in config")
    cpu = CpuTemp(g.getint("cpu_smoothing", 3))
    need_gpu = any(i.kind == "gpu" for f in fans for i in f.inputs)
    log(f"p620-fans start: hwmon={hwmon} cpu={cpu.path} interval={interval}s dry_run={a.dry_run}")
    for f in fans:
        log(f"  {f.name}: pwm{f.pwm} min={f.min_duty:.0f}% max={f.max_duty:.0f}% <- " +
            "; ".join(f"{i.kind}{'(' + ','.join(u[:12] for u in i.uuids) + ')' if i.uuids else ''} {i.curve}" for i in f.inputs))

    stop = {"flag": False}
    def handler(sig, _):
        stop["flag"] = True
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)

    cycle, last_report = 0, 0.0
    try:
        while not stop["flag"]:
            gpu_t = read_gpu_temps() if need_gpu else {}
            cpu_t = cpu.read()
            for f in fans:
                target, parts, alarm = 0.0, [], False
                for i in f.inputs:
                    t = i.temp(gpu_t, cpu_t)
                    if t is None:
                        d, why = 100.0, "NO TEMP"
                    elif t >= emerg[i.kind]:
                        d, why = 100.0, "EMERGENCY"
                    else:
                        eff = t
                        if i.last is not None and i.last - hyst < t < i.last:
                            eff = i.last
                        else:
                            i.last = t
                        d, why = interp(i.curve, eff), ""
                    alarm |= bool(why)
                    target = max(target, d)
                    parts.append(f"{i.kind} {t if t is not None else '?'}°C{' ' + why if why else ''}")
                target = max(target, f.min_duty)
                if not alarm and not f.started:
                    new, f.started = target, True
                else:
                    new = target if target >= f.duty else max(target, f.duty - step_down)
                f.apply(new)
                f.status, f.alarm = ", ".join(parts), alarm
            now = time.time()
            if now - last_report >= 30 or a.dry_run or any(f.alarm for f in fans):
                log("  |  ".join(f"{f.name} [{f.status}] {f.duty:5.1f}% {f.rpm()}rpm" for f in fans))
                last_report = now
            cycle += 1
            if a.cycles and cycle >= a.cycles:
                break
            time.sleep(interval)
    finally:
        gpu_t = read_gpu_temps() if need_gpu else {}
        cpu_t = cpu.raw()
        hot =(cpu_t is None or cpu_t >= 70 or (need_gpu and not gpu_t)
               or any(v >= 55 for v in gpu_t.values()))
        for f in fans:
            f.release(on_stop, hot)
        log("p620-fans stopped")

if __name__ == "__main__":
    main()
