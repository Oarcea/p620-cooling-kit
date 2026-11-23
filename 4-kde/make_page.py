#!/usr/bin/env python3
"""Generate a KDE System Monitor page combining each GPU / the CPU with its fans.

Cards are recognised by GPU UUID, so moving cards between PCIe slots is handled automatically:
  * KDE's sensor ids (gpu/gpu1, gpu2, ...) follow the DRM card order, which changes with the slots
  * the "GPU n" numbers shown are the CUDA / PyTorch indices (cuda:n), read from the NVIDIA driver
Re-run after changing slots:  python3 make_page.py --install   (then reopen System Monitor).
Without --install it writes p620-cooling.page next to this script.
"""
import ctypes, glob, os, subprocess, sys

NCT = "lmsensors/nct6686-isa-0a20"

# Physical cards: UUID -> (name, fan tach sensor or None, fan header) — keep in sync with /etc/p620-fans.conf
CARDS = {
    "GPU-5bb70be1-f1d0-4c22-c42f-064d81590f4d": ("P100-1", "fan6", "DIMM1"),
    "GPU-0bb243e3-ae6e-e054-68fc-cc5845ded711": ("P100-2", "fan7", "DIMM2"),
    "GPU-500e4d34-fa94-57e7-72e4-bb0e16f5de88": ("Quadro K2200", None, None),
}

def pci_key(addr):                      # "00000000:41:00.0" / "0000:41:00.0" -> "41:00.0"
    return addr.strip().lower()[-7:]

def nvidia_uuids():
    out = subprocess.run(["nvidia-smi", "--query-gpu=pci.bus_id,uuid", "--format=csv,noheader"],
                         capture_output=True, text=True, timeout=20).stdout
    return {pci_key(b): u.strip() for b, u in (l.split(",") for l in out.strip().splitlines())}

def kde_ids():
    """KDE names each GPU after its DRM card number: cardN -> gpuN.
    (Ubuntu 24.04 started at card1 -> gpu1; Ubuntu 26.04 / Plasma 6 starts at card0 -> gpu0.)"""
    cards = [c for c in glob.glob("/sys/class/drm/card[0-9]*") if c.rsplit("card", 1)[1].isdigit()]
    return {pci_key(os.path.basename(os.path.realpath(f"{c}/device"))): f"gpu{c.rsplit('card', 1)[1]}"
            for c in cards}

def cuda_order():
    """PCI addresses in CUDA device order (what PyTorch calls cuda:0, cuda:1, ...)."""
    try:
        cu = ctypes.CDLL("libcuda.so.1")
        if cu.cuInit(0):
            return []
        n = ctypes.c_int(); cu.cuDeviceGetCount(ctypes.byref(n))
        res = []
        for i in range(n.value):
            d = ctypes.c_int(); cu.cuDeviceGet(ctypes.byref(d), i)
            buf = ctypes.create_string_buffer(32); cu.cuDeviceGetPCIBusId(buf, 32, d)
            res.append(pci_key(buf.value.decode()))
        return res
    except OSError:
        return []

uuid_at, kde_at, order = nvidia_uuids(), kde_ids(), cuda_order()
GPUS = []          # (cuda index or None, kde id, name, fan, header, pci)
for pci, uuid in uuid_at.items():
    name, fan, header = CARDS.get(uuid, (f"unknown GPU {uuid[:12]}", None, None))
    if pci not in kde_at:
        print(f"warning: {name} at {pci} has no DRM card, skipped", file=sys.stderr); continue
    GPUS.append((order.index(pci) if pci in order else None, kde_at[pci], name, fan, header, pci))
GPUS.sort(key=lambda g: (g[0] is None, g[0] if g[0] is not None else 0, g[5]))

METRIC = {"temperature": "temperature", "power": "power", "usage": "load",
          "coreFrequency": "clock", "usedVram": "memory used"}
LABELS, ROWS = {}, []
for idx, kid, name, fan, header, pci in GPUS:
    short = f"GPU {idx} · {name}" if idx is not None else name
    LABELS.update({f"gpu/{kid}/{m}": f"{short} {txt}" for m, txt in METRIC.items()})
    fans = [f"{NCT}/{fan}"] if fan else []
    if fan:
        LABELS[f"{NCT}/{fan}"] = f"{header} fans ({name})"
    title = f"{short} · PCI {pci} · " + (f"{header} fans" if fan else "own fan")
    ROWS.append((title, [f"gpu/{kid}/temperature"], fans,
                 [f"gpu/{kid}/temperature"] + fans + [f"gpu/{kid}/{m}" for m in
                  ("power", "usage", "coreFrequency", "usedVram")]))
    print(f"{short:22} PCI {pci}  KDE {kid}  fan {header or '-'}", file=sys.stderr)

LABELS.update({
    f"{NCT}/fan1": "CPU fan A", f"{NCT}/fan2": "CPU fan B",
    # p620/cpu/temperatureAverage comes from the ksystemstats-p620 plugin (same 16 s average the fan controller uses)
    "p620/cpu/temperatureAverage": "CPU temperature (16 s average)",
    "cpu/all/maximumTemperature": "CPU Tctl (instant, spiky)",
    "cpu/all/usage": "CPU load", "cpu/all/averageFrequency": "CPU clock (average)",
})
ROWS.append(("CPU · Threadripper PRO 3975WX · cooler fans",
     ["p620/cpu/temperatureAverage", "cpu/all/maximumTemperature"], [f"{NCT}/fan1", f"{NCT}/fan2"],
     ["p620/cpu/temperatureAverage", "cpu/all/maximumTemperature", f"{NCT}/fan1", f"{NCT}/fan2",
      "cpu/all/usage", "cpu/all/averageFrequency"]))

def jl(xs):
    return "[" + ",".join(f'"{x}"' for x in xs) + "]"

faces, layout = [], []
fid = 100
def face(kind, title, high, low=(), extra=None):
    global fid
    fid += 1
    name = f"Face-{fid}"
    s = [f"[{name}][Appearance]", f"chartFace=org.kde.ksysguard.{kind}", f"Title={title}", "",
         f"[{name}][Sensors]", f"highPrioritySensorIds={jl(high)}"]
    if low:
        s.append(f"lowPrioritySensorIds={jl(low)}")
    s.append("")
    labels = [(x, LABELS[x]) for x in list(high) + list(low) if x in LABELS]
    if labels:
        s.append(f"[{name}][SensorLabels]")
        s += [f"{k}={v}" for k, v in labels]
        s.append("")
    if extra:
        s.append(f"[{name}][org.kde.ksysguard.{kind}][General]")
        s += [f"{k}={v}" for k, v in extra.items()]
        s.append("")
    faces.append("\n".join(s))
    return name

layout += ["[page]", "icon=temperature-normal", "margin=2", "loadType=onstart",
           "Title=GPUs & Cooling", ""]
row = 0
for title, temps, fans, details in ROWS:
    layout += [f"[page][row-{row}]", "isTitle=true", f"name=row-{row}", "heightMode=minimum",
               f"Title={title}", ""]
    row += 1
    cols = [face("linechart", "Temperature", temps,
                 extra={"rangeAutoY": "false", "rangeFromY": 25, "rangeToY": 90,
                        "showLegend": "false", "lineChartFillOpacity": 20, "historyAmount": 120})]
    if fans:
        cols.append(face("linechart", "Fan speed", fans,
                         extra={"rangeAutoY": "false", "rangeFromY": 0,
                                "rangeToY": 16000 if "fan6" in fans[0] or "fan7" in fans[0] else 6000,
                                "showLegend": "true" if len(fans) > 1 else "false",
                                "lineChartFillOpacity": 20, "historyAmount": 120}))
    cols.append(face("textonly", "Now", details))
    layout += [f"[page][row-{row}]", "isTitle=false", f"name=row-{row}", "heightMode=balanced",
               "Title=", ""]
    for c, fname in enumerate(cols):
        layout += [f"[page][row-{row}][column-{c}]", f"name=column-{c}", "showBackground=true",
                   "noMargins=false", "",
                   f"[page][row-{row}][column-{c}][section-0]", f"face={fname}",
                   "isSeparator=false", "name=section-0", ""]
    row += 1

if "--install" in sys.argv:
    # A running System Monitor writes its in-memory copy of the page back when it closes, merging the
    # old sensor ids into this file. Close it first (the login unit runs before it can be open).
    if subprocess.run(["pgrep", "-x", "plasma-systemmo"], capture_output=True).returncode == 0:
        sys.exit("System Monitor is open: close it first, then run this again "
                 "(otherwise it overwrites the new page with the old one when it closes)")
    out = os.path.expanduser("~/.local/share/plasma-systemmonitor/p620-cooling.page")
    os.makedirs(os.path.dirname(out), exist_ok=True)
else:
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "p620-cooling.page")
with open(out, "w") as f:
    f.write("# P620: GPUs and CPU combined with the fans that cool them (generated by make_page.py)\n\n")
    f.write("\n".join(faces) + "\n" + "\n".join(layout))
print(out)
