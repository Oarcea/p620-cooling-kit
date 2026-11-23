# ThinkStation P620 cooling kit

Everything needed to rebuild the fan control on this Lenovo ThinkStation P620 after an OS reinstall
or a move to another Linux distribution. Built and verified 16–18 Nov 2026 on Ubuntu 24.04, moved to Ubuntu 26.04 on 20–23 Nov 2026 (last update:
config v10, 15k rpm cap on the P100 shroud fans).

| | |
|---|---|
| Machine | Lenovo ThinkStation P620, Threadripper PRO 3975WX (32 cores), 62 GB RAM |
| GPUs | 2× Tesla P100 PCIe 16 GB (passive; shroud with **two 40 mm Arctic S4028-15K fans each**, on a Y-splitter per card), Quadro K2200 (display; was a P4000 until Nov 2026) |
| Firmware | BIOS S07KT0EA, EC S07ES14A |
| OS when built | Ubuntu 24.04.5, kernel 7.0.0-43-generic, NVIDIA 580.178.04, KDE Plasma 5.27.12, Secure Boot **off** |
| **OS now** | **Ubuntu 26.04.1**, kernel 7.0.0-44-generic, NVIDIA 580.178.04, KDE Plasma 6.6, Python 3.14, Secure Boot **on** (reinstalled and re-verified 20–23 Nov 2026, §4c) |
| Fan chip | Nuvoton NCT6686D Super I/O / EC (chip ID 0xd441, hwmon base 0xA20) |

**Reinstalling Ubuntu 26.04? Follow §4c** (exactly what this machine runs now). **Moving to Debian 13? Follow §4b.**

**Back up this whole folder** (USB stick, NAS or a git repo) before you reinstall. It holds the
driver source, so it does not depend on GitHub still having it.

---

## 1. Kit contents

| Folder | What | Install as |
|---|---|---|
| `1-driver/` | `install-driver.sh` and a snapshot of the out-of-tree **nct6687d** driver (`nct6687d-src/`, commit in `SOURCE.txt`) | `sudo bash install-driver.sh`, then reboot |
| `2-sensors/` | `p620-nct6686.conf`: lm-sensors labels for the headers | `sudo bash install-labels.sh` |
| `3-fans/` | **p620-fans** service: `p620-fans.py` daemon, `p620-fans.conf` curves (v9), systemd unit, `install.sh`; earlier versions in `curve-history/`; `variants/p620-fans.gpu-only.conf` hands CPU/case fans back to the BIOS | `sudo bash install.sh` |
| `4-kde/` | KDE System Monitor page "GPUs & Cooling" (regenerated at every login for the current slot layout) and the `ksystemstats-p620` plugin (smooth CPU temperature) | `bash install.sh` as your normal user |
| `5-tests/` | Stress tests, fan identification and diagnostics | see §8 |
| `6-results/` | Logs from every test run (CSV), summarised in §9 | none |

---

## 2. Hardware map: which header drives which fan

Identified by pulsing each channel and by loading each GPU (16–18 Nov 2026).

| Board header | hwmon PWM | Tach | Fan | Controlled by |
|---|---|---|---|---|
| CPU fan | `pwm1` | `fan1` + `fan2` | CPU cooler, 2 fans on one channel (≈1,400 rpm at 20 %, 4,400–4,700 at 100 %) | **p620-fans**, CPU curve |
| (none found) | `pwm2` | none | nothing attached | none |
| PSU | `pwm3` | `fan3` | Power-supply fan (≈2,700 idle, 2,900 under 700 W) | firmware (left alone on purpose) |
| Front-panel fan | `pwm4` | `fan4` | Front intake, **currently empty**: the fan on ODD_FAN is meant to move here | **p620-fans**, CPU curve |
| Rear fan | `pwm5` | `fan5` | Rear exhaust (≈1,400 at 25 %, 4,000 at 100 %) | **p620-fans**, CPU curve |
| DIMM1 | `pwm6` | `fan6` | **P100-1**: 2× 40 mm Arctic S4028-15K on a Y-splitter (≈1,330 rpm floor at 0 %, ≈16,000 at 100 %) | **p620-fans**, P100-1 curve |
| DIMM2 | `pwm7` | `fan7` | **P100-2**: 2× same fans on a Y-splitter | **p620-fans**, P100-2 curve |
| (none found) | `pwm8` | none | nothing attached | none |
| ODD_FAN | none | none | Fixed 12 V, always full speed, **not controllable or visible** (none of the 16 EC tach inputs) | nothing |

- **The DIMM rows depend on how the fan cables are plugged in.** Verified on 18 Nov 2026 with
  `5-tests/p620_gpu_fan_map.sh`. The pairing was swapped for a while (config v7, §7), and after
  any re-cabling it must be checked again.
- **Splitter tach:** with a Y-splitter only one fan of each pair reports rpm. Single readings of
  0 or about 6,000 rpm are splitter glitches; check by eye that both fans spin.

- **DIMM header current:** the DIMM headers were designed for the original 40 mm memory fans
  (Lenovo P1A040H12N, 0.49 A). Two Arctic fans (about 0.3 A each, 0.6 A total) on one header
  through a Y-splitter are fine.
- **BIOS fallback** (Setup → Power, or `think-lmi` under
  `/sys/class/firmware-attributes/thinklmi/attributes/`):
  - `FanControlStepping`: 1 = lowest … 7 = highest; set to **7**.
  - `QuadM2PCIeCardFanControl`: Low / Medium / High.
  - These only shape the firmware's own curve. They don't matter while p620-fans is running.

---

## 3. How it works

1. **Kernel driver `nct6687`** (out of tree, DKMS). The stock `nct6683` driver recognises the
   NCT6686D but is **read-only** and refuses Lenovo's customer ID 0x0511. `nct6687` uses the
   EC's manual-PWM handshake (registers 0xA00 / 0xA01 / 0xA28+x). The hwmon device is named
   `nct6686`, and lm-sensors calls the chip `nct6686-isa-0a20`.
   - `pwmN_enable = 1` means manual: Linux sets the duty.
   - `pwmN_enable = 2` means the firmware's own curve.
2. **Kernel parameter `acpi_enforce_resources=lax`.** ACPI claims the EC ports 0xA24–0xA27
   (OperationRegion ECS1), so without this parameter the driver isn't allowed to load. Sharing
   the ports is safe here because the firmware only touches them from a WMI method
   (GUID 18869F9A…, HSI_ WMAA ECRD/ECWR), which Linux never calls.
3. **`p620-fans` systemd service** (`/usr/local/sbin/p620-fans`, configured in
   `/etc/p620-fans.conf`, written in Python with the standard library only). Every 2 s it:
   - reads each P100 temperature by **GPU UUID** through `nvidia-smi`, since PCI bus numbers
     change between boots;
   - reads CPU **Tctl** (`k10temp temp1`) and averages it over 8 readings (16 s);
   - interpolates each fan's curve and writes the duty to its pwm header.
4. **Fail-safes** built into the service:
   - **Emergency:** a P100 at ≥ 79 °C or CPU at ≥ 90 °C forces that fan to 100 % (P100 thermal
     slowdown starts at 82 °C).
   - **No GPU temperature** (driver crashed, `nvidia-smi` hangs, card missing): the GPU fan
     goes to 100 % ("NO TEMP").
   - **Ramping:** speed increases happen immediately. Decreases are limited to 3 % per cycle,
     with 2 °C hysteresis.
   - **On stop:** the fans stay in manual mode at 100 % if anything is hot (CPU ≥ 70 °C, a GPU
     ≥ 55 °C, or no GPU reading), otherwise at 50 %. They are never handed back to the firmware,
     whose curve leaves the DIMM headers at 0 %, which is bad for passive P100s.
   - `Restart=always` brings the service back 3 s after a crash.
5. **The PSU fan (`pwm3`) is deliberately left on firmware control.** It already ramps with load,
   and nothing else should touch the PSU.

### Why the CPU temperature is averaged

Threadripper Tctl is the CPU's internal control temperature, not a physical package sensor. It
jumps 9–10 °C within 0.5 s whenever a light task such as a Firefox tab wakes a core, then falls
back over about 5–10 s, while the chiplets themselves stay around 45–50 °C.
- **With a 6 s average** (v5), the CPU fan swung between 32 % and 54 % on every burst.
- **With the 16 s average and a curve that stays flat up to 58 °C** (v6), it holds 22–26 %
  during desktop use.
- **Under sustained load** the fans still reach 100 % within about a minute.

The board has no smooth package sensor of its own:
- `nct6686 temp1` ("CPU") is just a copy of Tctl.
- `temp5` ("CPU Socket") reads 64 °C whether idle or at 270 W, so it's useless.

---

## 4. Fresh install (Ubuntu / Debian / Mint): quick path

Do the steps in this order. Each script says what it does and how to undo it.

```bash
# 0. Prerequisites: NVIDIA driver (must support Pascal / sm_60), lm-sensors, build tools
sudo apt install lm-sensors dkms build-essential linux-headers-$(uname -r)
nvidia-smi                      # all three GPUs must be listed (see §10 if a P100 is missing)
sudo systemctl enable --now nvidia-persistenced 2>/dev/null || true

# 1. Driver + kernel parameter, then REBOOT
sudo bash 1-driver/install-driver.sh
sudo reboot

# 2. After reboot: check the driver, then install the labels
grep -o acpi_enforce_resources=lax /proc/cmdline
sudo bash 5-tests/p620_verify_pwm.sh      # each header goes to 100 % for 6 s, then back to auto
sudo bash 2-sensors/install-labels.sh

# 3. Fan service
sudo bash 3-fans/install.sh
journalctl -u p620-fans -f                # one status line every 30 s
sudo bash 5-tests/p620_gpu_fan_map.sh     # MUST say "MAPPING OK"; if SWAPPED, swap pwm 6/7 (§7)

# 4. KDE only: System Monitor page + smooth-CPU-temperature plugin
sudo apt install cmake g++ extra-cmake-modules libkf5sysguard-dev libkf5coreaddons-dev qtbase5-dev
bash 4-kde/install.sh                     # as your user; asks for sudo to copy the plugin

# 5. Optional: Mission Center (flatpak) — see §11
```

### Checks after installing

- **Driver:** `sensors nct6686-isa-0a20` shows fans 1–7 with the labels above.
- **Service:** `systemctl status p620-fans` reports **active**, and the journal shows lines like
  `P100-1 [gpu 56.0°C] 15.0% 2700rpm | … | CPU [cpu 44.5°C] 20.5% 1400rpm …`.
- **Idle behaviour (v9):**
  - P100s at about 45–55 °C with their fans at the floor (0–15 %, about 1,300–1,500 rpm);
  - CPU fans about 1,400–1,700 rpm;
  - rear fan about 1,400–1,550 rpm.
- **Under load:** run `bash 5-tests/p620_system_stress.sh 600`. Expect about what §9 shows for v9:
  P100s at 74–75 °C with fans at 65–70 %, and CPU at about 76 °C.

---

## 4b. Debian 13 "trixie": step by step

Checked against Debian 13 on 18 Nov 2026, from what's in this kit:
- **Kernel 6.12 LTS:** the driver uses no kernel API newer than 6.1. Its only version check is
  for kernels before 6.1, and it has no `.remove` callback, which changed in 6.11–6.13.
- **Python 3.13:** the fan service only uses the standard library.
- **Plasma 6.3:** the KDE plugin now builds for Qt5 *and* Qt6.
- **Not test-built yet:** the driver against real 6.12 headers, and the plugin on Plasma 6.
  If either build fails, the install scripts stop cleanly without changing anything else (§10).

**Copy the kit off the USB stick first.** The stick is FAT32, which drops file permissions.
Unpacking the archive keeps them:

```bash
tar xzf /media/$USER/DA/p620-cooling-kit.tar.gz -C ~      # or: cp -r /media/$USER/DA/p620-cooling-kit ~
cd ~/p620-cooling-kit
```

**0. sudo.** If you set a root password during the Debian install, your user isn't in the
`sudo` group yet. Fix that once, then log out and back in:

```bash
su -c 'apt install sudo && /usr/sbin/usermod -aG sudo '"$USER"
```

**1. NVIDIA driver (Pascal: P100 = sm_60; display card K2200 = sm_50, Maxwell).** Debian's packaged driver comes from
`non-free`. The 550 series in trixie supports Pascal. The NVIDIA 580 series is the last to support
Pascal, so never install a 590+ driver on this machine.

```bash
sudo sed -i 's/^Components: main.*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
sudo apt update
sudo apt install linux-headers-amd64 nvidia-driver nvidia-smi nvidia-persistenced firmware-misc-nonfree
sudo reboot
nvidia-smi -L        # must list both P100s and the K2200
```

- **Repository format:** on an older-style `/etc/apt/sources.list` instead of `debian.sources`,
  add `contrib non-free non-free-firmware` after `main` by hand.
- **`nvidia-smi` is a separate package on Debian.** Without it the fan service sees no GPU
  temperature and runs both P100 headers at 100 % ("NO TEMP").

**2. Driver for the fan chip + kernel parameter.**

```bash
sudo apt install dkms build-essential lm-sensors
sudo bash 1-driver/install-driver.sh       # GRUB: writes /etc/default/grub.d/99-nct6687.cfg + update-grub
sudo reboot
grep -o acpi_enforce_resources=lax /proc/cmdline && sensors nct6686-isa-0a20
```

**Secure Boot on:** Debian's DKMS signs the module with its own key, which you enroll once:
1. `sudo mokutil --import /var/lib/dkms/mok.pub` (choose a one-time password);
2. reboot, then pick "Enroll MOK" in the blue screen.

The NVIDIA driver needs the same key, so if `nvidia-smi` works, the key is probably already enrolled.

**systemd-boot instead of GRUB** (expert install): the script appends the parameter to
`/etc/kernel/cmdline`. Afterwards run `sudo kernel-install add $(uname -r) /boot/vmlinuz-$(uname -r)`
and reboot.

**3. Labels, fan service, wiring check.**

```bash
sudo bash 5-tests/p620_verify_pwm.sh
sudo bash 2-sensors/install-labels.sh
sudo bash 3-fans/install.sh
journalctl -u p620-fans -n 5
```

`p620_gpu_fan_map.sh` (next step) needs a PyTorch environment for the GPU load. Set it up once.
Use **CUDA 12.x wheels**, because CUDA 13 dropped Pascal:

```bash
sudo apt install python3-venv
python3 -m venv ~/torch-p100
~/torch-p100/bin/pip install torch --index-url https://download.pytorch.org/whl/cu126
sudo PY=$HOME/torch-p100/bin/python bash 5-tests/p620_gpu_fan_map.sh     # must end with MAPPING OK
```

If it says **SWAPPED**, switch the pairing as described in §7.

**4. KDE Plasma 6.**

```bash
sudo apt install cmake g++ extra-cmake-modules libksysguard-dev libkf6coreaddons-dev qt6-base-dev
bash 4-kde/install.sh                      # as your user; prints a temperature at the end if the plugin loaded
```

**5. Check under load.**

```bash
gcc -O2 -mavx2 -mfma -fopenmp -o 5-tests/cpu/cpu_burn 5-tests/cpu/cpu_burn.c
PY=$HOME/torch-p100/bin/python bash 5-tests/p620_system_stress.sh 600
```

Compare with the v9 row in §9: P100s at about 74 °C with fans at 65–68 %, CPU at about 76 °C.

**Mission Center on Debian:**
- install it from Flathub with `sudo apt install flatpak` plus the Flathub remote;
- the NVIDIA GL extension has to match Debian's driver version (e.g. `GL.nvidia-550-163-01`); see §11.

---

## 4c. Ubuntu 26.04 + Plasma 6: step by step (verified 20–23 Nov 2026)

This is exactly what was run on this machine. Secure Boot was **on** and stayed on.

**Copy the kit off the stick first.** On the FAT32 stick nothing can be executed (`cpu_burn` won't run):

```bash
cp -r /run/media/$USER/DA/p620-cooling-kit ~/ && cd ~/p620-cooling-kit
find . -name '*.sh' -o -name '*.py' | xargs chmod +x
```

**1. Driver + kernel parameter.** `nvidia-driver-580` already pulls in `dkms` and `build-essential`.
Ubuntu's DKMS signs `nct6687` with the MOK key that already signs the NVIDIA module
(`/var/lib/shim-signed/mok/`), so no extra enrollment is needed if `nvidia-smi` works.

```bash
sudo apt install cmake extra-cmake-modules libksysguard-dev libkf6coreaddons-dev qt6-base-dev   # for step 4
sudo bash 1-driver/install-driver.sh          # wait for "== 4/4 Done" BEFORE rebooting
sudo reboot
grep -o acpi_enforce_resources=lax /proc/cmdline && sensors nct6686-isa-0a20
```

The kernel log then shows "ACPI: OSL: Resource conflict"; that's the expected effect of `lax`.

**2. Header test, labels, fan service, KDE page** (one sudo prompt for all of it):

```bash
sudo bash 5-tests/p620_verify_pwm.sh && sudo bash 2-sensors/install-labels.sh && sudo bash 3-fans/install.sh && bash 4-kde/install.sh
```

The KDE plugin check at the end must print `p620/cpu/temperatureAverage <number>`.

**3. PyTorch for the GPU tests.** Python 3.14 needs `python3-venv`; the CUDA 12.6 wheel still has `sm_60`:

```bash
sudo apt install python3-venv && python3 -m venv ~/torch-p100
~/torch-p100/bin/pip install torch --index-url https://download.pytorch.org/whl/cu126      # ~3 GB (torch 2.14.1 worked)
sudo PY=$HOME/torch-p100/bin/python bash 5-tests/p620_gpu_fan_map.sh                       # must say MAPPING OK
```

**4. Stress test** (runs as your user):

```bash
gcc -O2 -mavx2 -mfma -fopenmp -o 5-tests/cpu/cpu_burn 5-tests/cpu/cpu_burn.c
PY=$HOME/torch-p100/bin/python bash 5-tests/p620_system_stress.sh 600
```

Expect what §9 shows for v10: CPU about 72–76 °C, both P100s at 74 °C with fans at 62–72 %.

**Differences from 24.04 that the kit now handles:**
- **KDE GPU ids start at `gpu0`** (DRM `card0`); `make_page.py` maps `cardN` → `gpuN`. Close System Monitor
  before regenerating the page, or it writes the old page back when it closes (§10).
- **The plugin needs QtQml on Plasma 6**; `CMakeLists.txt` links it.
- **CPU power (RAPL) is root-only**, so `cpu_W` in `system_stress.csv` is 0 when run as a user. The test still works.
- **`3-fans/install.sh` restarts the service**, so a changed `p620-fans.py` or config takes effect immediately.

---

## 5. Other distributions

The service, labels and test scripts work on any **systemd** distribution. Two things are
distribution-specific: building the driver, and setting the kernel parameter.

### 5a. Driver build dependencies

| Distro | Command |
|---|---|
| Fedora / RHEL / Alma / Rocky | `sudo dnf install dkms kernel-devel-$(uname -r) make gcc lm_sensors` |
| Arch / EndeavourOS / Manjaro | `sudo pacman -S dkms linux-headers base-devel lm_sensors` (use the headers that match your kernel, e.g. `linux-lts-headers`). The AUR has `nct6687d-dkms-git` as an alternative. |
| openSUSE | `sudo zypper install dkms kernel-default-devel make gcc sensors` |
| Debian / Ubuntu / Mint / Pop | `sudo apt install dkms linux-headers-$(uname -r) build-essential lm-sensors` |

Then run `sudo bash 1-driver/install-driver.sh`. If the build fails on a much newer kernel,
replace `1-driver/nct6687d-src/` with a fresh `git clone https://github.com/Fred78290/nct6687d`
and run the script again.

If the kernel ever gains write support for the NCT6686D in `nct6683`, this driver won't be
needed. Check with `modinfo nct6683` and the kernel changelog.

### 5b. Kernel parameter `acpi_enforce_resources=lax`

`install-driver.sh` detects the bootloader and sets the parameter automatically. To do it by hand:

| Bootloader / distro | How |
|---|---|
| GRUB on Debian/Ubuntu | file `/etc/default/grub.d/99-nct6687.cfg` (written by the script), then `sudo update-grub` |
| GRUB on Fedora/RHEL | `sudo grubby --update-kernel=ALL --args="acpi_enforce_resources=lax"` |
| GRUB on Arch / openSUSE | add it to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `sudo grub-mkconfig -o /boot/grub/grub.cfg` (openSUSE: `grub2-mkconfig -o /boot/grub2/grub.cfg`) |
| systemd-boot (Pop!_OS) | `sudo kernelstub -a acpi_enforce_resources=lax` |
| systemd-boot / UKI (Arch, Fedora Atomic…) | append it to `/etc/kernel/cmdline` or to the `options` line in `/boot/loader/entries/*.conf`, then regenerate the boot entries |
| Fedora Atomic (Silverblue/Kinoite) | `rpm-ostree kargs --append=acpi_enforce_resources=lax` (DKMS is awkward on atomic distros; consider a regular Fedora) |

After rebooting, check with `cat /proc/cmdline`.

### 5c. Secure Boot

It was **off** on this machine. If you turn it on, the DKMS module must be signed:
- **Ubuntu:** DKMS asks you to enroll a MOK key at the next boot.
- **Fedora:** use `kmodtool`/`akmods` keys, or `mokutil --import` your own key.

Without a signed module, `nct6687` won't load, and the fan service will refuse to start
("nct6686 hwmon device missing").

### 5d. Fan service paths

`3-fans/install.sh` copies files to `/usr/local/sbin`, `/etc` and `/etc/systemd/system`, which
works on every systemd distribution. The unit runs `/usr/bin/python3`. If python3 lives
elsewhere, edit `ExecStart` in `p620-fans.service`. The only external tool needed is `nvidia-smi`
(from the NVIDIA driver).

### 5e. KDE plugin on Plasma 6

Since 18 Nov 2026 the plugin builds for **both** Plasma 5 (Qt5) and Plasma 6 (Qt6).
- `CMakeLists.txt` picks Qt6 when `KF6CoreAddons` is installed (force it with `-DQT_MAJOR_VERSION=5|6`).
- `4-kde/install.sh` installs the plugin next to the stock `ksystemstats_plugin_cpu.so` of the
  same Qt version.
- The Qt5 build is tested. The Qt6 build was test-built on Ubuntu 26.04 / Plasma 6.6 (20 Nov 2026); it needs QtQml
  (`qt6-declarative-dev`, pulled in by `libksysguard-dev`), which `CMakeLists.txt` now links for Qt6. If it fails on Plasma 6,
  these are the manual steps it automates:
1. In `CMakeLists.txt`, replace `Qt5` with `Qt6` and `KF5CoreAddons` with `KF6CoreAddons`
   (target `KF6::CoreAddons`), and link `KSysGuardSystemStats` / `KSysGuardFormatter` from
   libksysguard 6. On Fedora that's `libksysguard-devel`; on Arch the headers ship with
   `libksysguard`.
2. In `p620plugin.cpp`, replace `qAsConst` with `std::as_const`. The `KSysGuard::SensorPlugin` API
   and `K_PLUGIN_CLASS_WITH_JSON` haven't changed.
3. Install it into the Qt6 plugin folder, e.g. `/usr/lib/qt6/plugins/ksystemstats/` (Arch) or
   `/usr/lib64/qt6/plugins/ksystemstats/` (Fedora). Running
   `find /usr -name ksystemstats_plugin_cpu.so` shows where.
4. Restart the sensor service with `systemctl --user restart plasma-ksystemstats` (on Plasma 6 the
   service may be called `ksystemstats`).

Without the plugin the page still works; only the "CPU temperature (16 s average)" line stays empty.

### 5f. Other desktops (GNOME, etc.)

The fan control itself doesn't depend on the desktop. To watch it, use any of these:
- `watch -n2 sensors nct6686-isa-0a20` plus `nvidia-smi`;
- `journalctl -u p620-fans -f`;
- Mission Center (§11).

Avoid CoolerControl and `fancontrol`: running them on the same headers would fight the service.

---

## 6. Fan curves (`/etc/p620-fans.conf`, currently v10)

Edit the file, then run `sudo systemctl restart p620-fans`. Curve points are `temp°C:duty%`,
linearly interpolated and flat beyond the ends. Each fan takes the highest duty from all of its
inputs.

```ini
[general]
interval = 2            # seconds per cycle
step_down = 3           # max duty decrease per cycle (%); increases are immediate
hysteresis = 2          # ignore temperature drops smaller than this (°C)
gpu_emergency_temp = 79
cpu_emergency_temp = 90
hwmon_name = nct6686
cpu_smoothing = 8       # Tctl averaged over 8 × 2 s = 16 s (also used by the KDE plugin)
on_stop = safe          # or "auto" = hand back to firmware (NOT recommended: DIMM headers go to 0 %)

[fan:P100-1]            # DIMM1 header, 2 fans; 75 °C needs 65 % at 241 W
pwm = 6
gpu_uuids = GPU-5bb70be1-f1d0-4c22-c42f-064d81590f4d
gpu_curve = 50:0 60:15 70:40 75:68 78:100
max_duty = 90           # hard cap ≈ 14,900 rpm (v10)

[fan:P100-2]            # DIMM2 header, 2 fans; 75 °C needs 69 % at 237 W
pwm = 7
gpu_uuids = GPU-0bb243e3-ae6e-e054-68fc-cc5845ded711
gpu_curve = 50:0 60:15 70:45 75:72 78:100
max_duty = 90           # hard cap ≈ 14,800 rpm (v10)

[fan:CPU]
pwm = 1
min_duty = 20
cpu_curve = 45:20 58:28 63:55 67:85 72:100

[fan:Rear]
pwm = 5
min_duty = 25
cpu_curve = 45:25 58:33 63:60 67:90 72:100

[fan:Front]             # empty header for now; harmless
pwm = 4
min_duty = 25
cpu_curve = 45:25 58:33 63:60 67:90 72:100
```

Other options:
- `max_duty` (per fan, default 100) is a hard ceiling that also caps the EMERGENCY / NO TEMP / on-stop
  100 % cases. v10 sets 90 % on both P100 headers: 100 % (≈16,100 rpm) gave audible resonance, and
  `5-tests/p620_fan_rpm_sweep.sh` measured 90 % = 14,800–14,900 rpm, 92 % = 15,200. Under full load the P100
  curves only reach 62–72 %, so the cap only matters above about 77 °C; the card still protects itself at 82 °C.
- A fan can follow several GPUs (`gpu_uuids = A, B`) or both a GPU and the CPU (set both
  `gpu_curve` and `cpu_curve`).
- `--dry-run` prints the duties the service would set without writing them.

**How the P100 curves were made (v9):** `5-tests/p620_gpu_fan_target.sh` loads both cards
(they heat each other) and uses a feedback controller to find the duty that holds each card at
75 °C. The curve passes through that duty + 3 % at 75 °C, so the card settles just under 75 °C,
and climbs to 100 % by 78 °C. To retune for another target, run it with e.g. `… 72 900`, then
move the 75 °C point. Also keep `gpu_emergency_temp` a few degrees above the new target.

**Your preference:** the front and rear case fans follow **only the CPU**. Case airflow doesn't
help the P100s, which have their own shroud fans.

### Curve history (`3-fans/curve-history/`)

| Version | Change | Result |
|---|---|---|
| firmware | BIOS auto | CPU fans stuck at 48 % while 266 W pushed Tctl 66 → 79 °C and still rising |
| v1 | first CPU + rear curves (45:20 60:35 70:55 78:80 85:100) | 75 °C at 72 % fan under 266 W |
| v2 | more aggressive (CPU 40:25 … 72:100) | 72 °C flat at 100 % fans |
| v3 | front header added (followed CPU + GPUs) | none |
| v4 | front/rear follow CPU only | none |
| v5 | quieter idle: lower bottom ends for everything | idle P100 fans 2,300 / 3,700 rpm (were 4,000 / 5,000+), CPU about 1,600 |
| v6 | `cpu_smoothing` 3 → 8, CPU curves flat up to 58 °C | no more fan bursts during desktop use; full load unchanged |
| v7 | P100-1 ↔ P100-2 headers swapped (pwm7 / pwm6) to match the fan cables after a slot change | curves unchanged |
| v8 | Y-splitters added (2 fans per P100); cables re-checked → pairing back to DIMM1 = P100-1, DIMM2 = P100-2 | full load: 68 °C at 243–248 W with fans at 80–90 % (more cooling than needed) |
| v9 | P100 curves retuned to settle at about 75 °C (measured duties + 3 %), `gpu_emergency_temp` 76 → 79 | full load: 74–75 °C at 240–247 W with fans at 65–68 %, about 1,500–2,500 rpm quieter than v8 |
| **v10** (23 Nov 2026) | `max_duty = 90` on both P100 headers (≈14,900 rpm ceiling instead of 16,100) against fan resonance; curves unchanged | full load still settles at 74 °C with fans at 62–72 %, so no change in normal use |

---

## 7. GPU identity: what happens when cards move between slots

**How the fan service pairs fans with GPUs.** Each `[fan:…]` section names a fan **header**
(`pwm = 6`) and a **GPU UUID**. The UUID is burned into the card itself, so it moves with the card.
Every 2 s the service asks `nvidia-smi` for "temperature of GPU-5bb70be1…", no matter which slot
that card is in. The physical link between a card and its fan is the **fan cable**: the 40 mm fan
sits on the card's shroud, and its cable goes to a header.

| You change… | Fan control | What to do |
|---|---|---|
| Move cards between PCIe slots, each card's fan cable stays on **its** header | ✔ still correct (follows the UUID) | nothing. KDE page: reopen System Monitor (§7b). |
| Fan cables swapped (P100-1's fan now on DIMM2) | ✘ **wrong**: each header follows the other card's temperature | check with `sudo bash 5-tests/p620_gpu_fan_map.sh`, then swap the cables back **or** swap `pwm = 6` / `pwm = 7` in `/etc/p620-fans.conf` |
| A card replaced (new UUID) | fail-safe: that header runs at **100 %** with `NO TEMP` in the log | put the new UUID (`nvidia-smi -L`) in `/etc/p620-fans.conf` and in `CARDS` in `4-kde/make_page.py` |
| A P100 fails to enumerate | same fail-safe: 100 % on its header | reseat it and cold boot |

What the fan service *cannot* see is which header a fan is plugged into. Wrong wiring is the one
mistake it can't catch on its own, which is what `p620_gpu_fan_map.sh` is for. That script:
- reads the pairing from the config;
- stops the service and loads both cards;
- runs each header at its floor in turn;
- reports **MAPPING OK** / **SWAPPED** (about 3½ min, and restarts the service at the end).

The danger with swapped cables: under load the hot card's own fan stays slow while the *other* card's fan
ramps up. The 79 °C emergency only forces the header *assigned* to the hot card to 100 %, which isn't
its fan, so the card sits at its 82 °C slowdown. It's protected by the card's own throttling, but loud
and slow.

### 7b. Numbering: which GPU is "GPU 0" changes with the slots

| Numbering | Depends on | Who uses it |
|---|---|---|
| **UUID** | the card (never changes) | p620-fans, `CARDS` in make_page.py |
| CUDA / PyTorch `cuda:N` | "fastest first" (the P100s come before the display card), then PCI bus order | your code, page titles "GPU N" |
| `nvidia-smi -i N` | PCI bus order | nvidia-smi |
| KDE `gpu/gpuN` | DRM card number: `cardN` → `gpuN` (24.04 started at card1, 26.04 / Plasma 6 at card0) | KDE System Monitor |

Layouts seen so far:

| Date | P100-1 (`5bb70be1`) | P100-2 (`0bb243e3`) | Display card (P4000 `dc8272dc` until 18 Nov, then K2200 `500e4d34`) |
|---|---|---|---|
| 16–17 Nov 2026 | PCI 41:00.0 · cuda:0 · KDE gpu2 · **DIMM1** fan | 61:00.0 · cuda:1 · gpu1 · **DIMM2** fan | 42:00.0 · cuda:2 · gpu3 |
| 17 Nov 2026, after a slot change | **42:00.0 · cuda:1** · gpu3 · **DIMM2** fan | **41:00.0 · cuda:0** · gpu2 · **DIMM1** fan | **61:00.0** · cuda:2 · gpu1 |
| **18 Nov 2026, splitters** | **41:00.0 · cuda:0** · gpu2 · **DIMM1** (2 fans) | **42:00.0 · cuda:1** · gpu3 · **DIMM2** (2 fans) | **62:00.0** · cuda:2 · gpu1 |
| **20 Nov 2026, Ubuntu 26.04, K2200 replaces the P4000 (current)** | 41:00.0 · cuda:0 · gpu0 · **DIMM1** (2 fans), MAPPING OK | 42:00.0 · cuda:1 · gpu2 · **DIMM2** (2 fans), MAPPING OK | K2200 `500e4d34` at 61:00.0 · cuda:2 · gpu1 |

`p620_gpu_fan_map.sh` reported **SWAPPED** twice: after the 17 Nov slot change, and again after
the splitters went in on 18 Nov (±17 °C each time). Both times the fix was made in software.
**To switch the pairing**, change all three together:
1. `/etc/p620-fans.conf`: swap `pwm = 6` / `pwm = 7` between `[fan:P100-1]` and `[fan:P100-2]`,
   then `sudo systemctl restart p620-fans`;
2. `2-sensors/p620-nct6686.conf` labels for fan6/fan7 (copy to `/etc/sensors.d/`);
3. `CARDS` in `4-kde/make_page.py` (`fan6`/`DIMM1` ↔ `fan7`/`DIMM2`), then
   `cp 4-kde/make_page.py ~/.local/bin/p620-cooling-page`.

Then run `sudo bash 5-tests/p620_gpu_fan_map.sh` again to confirm **MAPPING OK**.

So after a slot change, `cuda:0` in your code can be a different physical card. To pin it, use
`CUDA_VISIBLE_DEVICES=GPU-5bb70be1-…` (a UUID works there).

`4-kde/make_page.py` now works out the layout itself:
- it maps UUIDs to PCI addresses with `nvidia-smi`, then to KDE ids from the DRM order, and gets
  the CUDA order from the NVIDIA driver;
- titles look like `GPU 0 · P100-1 · PCI 41:00.0 · DIMM1 fans`.

`4-kde/install.sh` sets it up to run at every login (user unit `p620-cooling-page.service`), so a
slot change only needs a reboot or re-login. To refresh it by hand:
`python3 4-kde/make_page.py --install`, then reopen System Monitor.

## 8. Tests and tools (`5-tests/`)

**The GPU load needs a Python environment with CUDA PyTorch.** It used
`/home/p620/env_isaaclab/bin/python` (torch 2.10 cu128). Point the scripts at another one with
`PY=/path/to/python bash …`.
- torch builds without Pascal kernels still work, because the load only uses cuBLAS GEMM.
- NVIDIA Warp (CUDA 13) doesn't support sm_60.
- **Random data is essential:** a GEMM on zero-filled matrices only draws 126–172 W, while random
  data reaches the 250 W cap.

**The CPU load needs this one-time build:**
`gcc -O2 -mavx2 -mfma -fopenmp -o 5-tests/cpu/cpu_burn 5-tests/cpu/cpu_burn.c`.
On the FAT USB stick the binary can't be executable: build it to `~/.local/bin/p620-cpu-burn` instead and
run `CPU_BURN=~/.local/bin/p620-cpu-burn PY=~/torch-p100/bin/python bash 5-tests/p620_system_stress.sh 600`.

| Script | Purpose | Run |
|---|---|---|
| `p620_system_stress.sh [secs] [cpu_guard] [gpu_guard]` | **Main test.** CPU on 60 threads (AVX2 FMA, about 265–280 W) + both P100s (FP16 GEMM, 250 W cap). Logs every sensor every 5 s to `p620_diag/system_stress.csv`; stops the load at CPU 92 °C or GPU 84 °C; 2 min cooldown. | `bash p620_system_stress.sh 1200` |
| `p620_stress_long.sh [secs] [guard]` | Both P100s only | `bash …` |
| `cpu/cpu_stress_log.sh [secs] [guard] [name]` | CPU only, with RAPL package power | `bash …` |
| `p620_twofan_test.sh [secs] [card]` | Both 40 mm fans on one card (stops p620-fans during the test, restarts it after) | `sudo bash …` |
| `p620_gpu_fan_map.sh` | **After moving cards or re-plugging fans:** checks that each DIMM header cools the card the config says (by UUID). Pauses p620-fans for about 3½ min. | `sudo bash …` |
| `p620_gpu_fan_target.sh [target=75] [secs=900]` | Finds the fan duty that holds each P100 at a target temperature, with both cards at full load. Feedback loop per card; CPU fans 30 %, case fans 35 %. Pauses p620-fans. Basis of the v9 curves. | `sudo bash …` |
| `p620_fan_rpm_sweep.sh [duty% ...]` | rpm vs duty on DIMM1/DIMM2 (median of 6 reads per step, ignores splitter glitches); pauses p620-fans for about 2 min. Basis of the v10 `max_duty`. | `sudo bash …` |
| `p620_idle_compare.sh` | Idle logger (every 5 s): Tctl, CPU power, CPU/rear/front duty + rpm and mode (1 = service, 2 = BIOS). Stop with `touch p620_diag/idle_compare.stop`. | `bash …` |
| `p620_cpu_spike_monitor.sh [spike_temp]` | Logs Tctl / hottest chiplet / CPU fan every 0.5 s and records the busiest processes on each spike. Stop with `touch p620_diag/cpu_spikes.stop`. | `bash …` |
| `p620_verify_pwm.sh` | After installing the driver: write test on pwm1/3/5 plus a 60 s hold test | `sudo bash …` |
| `p620_identify_fans.sh [channels]` | Pulses each header 100 % ↔ 25 % so you can find the fan | `sudo systemctl stop p620-fans` first, then `sudo bash …` |
| `p620_test_channel.sh [ch]` | Slow 0 % / 100 % cycling of one header (for fans without a tach) | same as above |
| `p620_fan_diag.sh` | Full low-level diagnostics (DMI, Super I/O ID, ACPI dump, module tests). Installs i2c-tools / acpica-tools with apt. | `sudo bash …` |
| `p620_ec_probe.py [--no-write]` | Direct EC register probe, no driver needed | `sudo python3 -I …` |
| `gpu_burn.py`, `gpu_burn_jit.py` | GPU load generators used by the scripts above | none |

Run `system_stress` / `stress_long` as your normal user. The `p620_identify_fans.sh` and
`p620_test_channel.sh` scripts restore each channel when they finish, but p620-fans would
overwrite them every 2 s, so stop it first and start it again afterwards.

---

## 9. Results (logs in `6-results/`)

| Test | CPU | P100-1 | P100-2 | Notes |
|---|---|---|---|---|
| CPU only, firmware fans | 66 → 79 °C, rising, 266 W | none | none | reason for the custom curve |
| CPU only, v2 curve | **72 °C** flat, 266 W, fans 100 % | none | none | none |
| GPUs only, 10 min | none | 79 °C, 226 W, 1.25 GHz | 79 °C, 215 W, 1.22 GHz | thermal slowdown (0x20) |
| **Two fans on P100-1** | none | **64 °C, 239–246 W, 1.32 GHz** | none | only the power cap limits it: the 2nd fan per card gives full TDP |
| Whole system, 10 min (v5) | 75.4 °C, 269 W, 3.57 GHz | 78.8 °C, 223 W | 78.8 °C, 213 W | about 705 W from the 3 chips; PSU fan 2,650 → 2,920 rpm |
| **Whole system, 20 min (v6)** | **73.4 °C** (max 75), 264 W, 3.54 GHz | 78.9 °C, 221 W, 1.26 GHz | 78.9 °C, 213 W, 1.21 GHz | VRM 45, chipset 45, PCIe 50, M.2 51, NVMe 44 (max 49), P4000 40 °C; fans back to idle about 60 s after the load stops |
| Idle (v6) | about 44–55 °C (Tctl) | 55–56 °C, fan 15–20 % | 56 °C, fan 20 % | CPU fans about 1,400–1,700 rpm |
| Idle, BIOS auto vs v7 (`idle_compare.csv`) | BIOS: Tctl 40 °C, CPU fans 57 % (≈3,000 rpm), rear 69 % (≈2,970). v7: Tctl 44–50 °C, CPU 20–21 % (≈1,400), rear 25 % (≈1,400) | none | none | the BIOS curve is about 2× the rpm for a 6–8 °C cooler idle CPU |
| **Two fans per P100 (splitters)** | | | | |
| Whole system, v8 curves (`system_stress_run3_v8_partial.csv`, 4½ min) | 72.8 °C, 275 W | 68 °C, 248 W, 1.32 GHz, fans 80 % (≈13,300 rpm) | 68 °C, 243 W, fans 90 % (≈13,900 rpm) | only the power cap limits it, no thermal throttling |
| 75 °C hold test (`gpu_fan_target.csv`, 15 min, CPU idle) | 72 °C | **75 °C needs 65 %** (≈11,700 rpm), 241 W, 1.30 GHz | **75 °C needs 69 %** (≈12,400 rpm), 237 W, 1.29 GHz | power cap only |
| **Whole system, v9 curves** (`system_stress_run4_v9_splitters.csv`, 5½ min, stable after 3) | **75.9 °C** (max 77), 282 W, 3.61 GHz, fans 100 % | **74 °C** (max 75), 247 W, 1.30 GHz, fans 65 % | **74 °C** (max 75), 240 W, 1.29 GHz, fans 68 % | no thermal throttling; P4000 45, VRM 44, PCH 45, PCIe 48, M.2 48, NVMe 44 °C; PSU fan 2,900 rpm |
| **Whole system, v9, Ubuntu 26.04** (`system_stress_run5_v9_ubuntu2604.csv`, 10 min, side panel on, 20 Nov 2026) | **72 °C** (max 73), 3.53 GHz, fans 100 % | **74 °C** (max 75), 241 W, 1.30 GHz, fans 62 % | **73 °C** (max 73), 233 W, 1.29 GHz, fans 66 % | no thermal throttling (power cap only); K2200 49, VRM 42, PCH 43, PCIe 47, M.2 48, NVMe 42 °C; PSU fan 2,460 rpm. CPU power not logged (RAPL is root-only on 26.04) |
| **Whole system, v10 (90 % cap)** (`system_stress_run6_v10_cap90_partial.csv`, 4½ min, stopped once stable, 23 Nov 2026) | 76 °C (max 77), 3.63 GHz, fans 100 % | **74 °C** (max 75), 246 W, 1.30 GHz, fans 62–67 % (max 12,244 rpm) | **74 °C** (max 75), 239 W, 1.29 GHz, fans 66–72 % (max 13,043 rpm) | power cap only; the 90 % cap (≈14,900 rpm) was never reached, so cooling is unchanged from v9 |

Limits:
- **P100:** slowdown at 82 °C, shutdown at 85 °C, 250 W power cap.
- **3975WX:** Tjmax 95 °C.

Summary:
- **CPU:** about 20 °C of headroom at full load. It runs about 3 °C warmer when the GPUs are
  at 75 °C rather than 68 °C, since the case air is warmer.
- **P100s, one fan each:** they sat at the 79 °C thermal slowdown with 213–226 W.
- **P100s, two fans each:** they run the full 250 W power cap. v9 trades about 6 °C (68 → 74 °C)
  for about 2,000 rpm less fan speed, with no performance loss beyond a 1–2 % lower boost clock.

---

## 10. Troubleshooting

| Symptom | Check / fix |
|---|---|
| `sensors` has no `nct6686-isa-0a20` | `lsmod \| grep nct6687`; `dmesg \| grep -i -E 'nct66\|resource conflict'`. "ACPI resource conflict" means the kernel parameter is missing (§5b). Module missing means DKMS didn't build for this kernel: `dkms status`, then `sudo dkms autoinstall`. |
| `nct6683` loaded instead | `/etc/modprobe.d/nct6687.conf` must blacklist it, then reboot |
| p620-fans won't start | `journalctl -u p620-fans -b`; usually the hwmon device is missing (see above) |
| P100 fans at 100 % all the time, log says `NO TEMP` | `nvidia-smi` is failing or a P100 is missing. Check `nvidia-smi -L`. A P100 that doesn't enumerate usually comes back after reseating it and a cold boot. |
| P100 fans at 100 %, log says `EMERGENCY` | GPU at ≥ 79 °C. With two fans per card this shouldn't happen. Check that both fans spin, that the pairing is right (`p620_gpu_fan_map.sh`), and that the shroud and filters aren't dusty. |
| One P100 runs hot while the *other* card's fans ramp | fan cables swapped: run `sudo bash 5-tests/p620_gpu_fan_map.sh` and fix the pairing (§7) |
| fan6/fan7 show 0 or about 6,000 rpm for a moment | splitter tach glitch (only one fan of each pair reports); harmless |
| Want the BIOS curve for CPU/case fans | `sudo install -m 0644 3-fans/variants/p620-fans.gpu-only.conf /etc/p620-fans.conf && sudo systemctl restart p620-fans && echo 2 \| sudo tee /sys/class/hwmon/hwmon*/pwm[145]_enable`. Back: install `3-fans/p620-fans.conf` and restart. |
| CPU fans "breathing" | raise `cpu_smoothing` (8 → 10), or flatten the low end of `cpu_curve` |
| Fans at a fixed 50 % / 100 % | the service is stopped (on_stop=safe). Start it: `sudo systemctl start p620-fans` |
| Give everything back to the BIOS | `sudo systemctl disable --now p620-fans`, then `echo 2 \| sudo tee /sys/class/hwmon/hwmon*/pwm[14567]_enable` |
| KDE page: "CPU temperature (16 s average)" empty | plugin not installed for this Plasma version (§5e). Test it: `kstatsviewer --remain p620/cpu/temperatureAverage` |
| KDE GPU rows show the wrong card | the page is rebuilt at login; refresh by hand: **close System Monitor first** (an open one writes the old page back when it closes), then `~/.local/bin/p620-cooling-page --install` and reopen it. If the fan rows are wrong, fix `CARDS` in `make_page.py` (§7). |
| Shell scripts print wrong numbers | the scripts set `LC_ALL=C`, because your ro_RO locale uses a decimal comma that breaks `printf %f`; keep that line |

---

## 11. Mission Center (flatpak)

- **Crashes at start (EGL error):** the flatpak NVIDIA GL extension must match the host driver
  version exactly:
  ```bash
  flatpak install flathub org.freedesktop.Platform.GL.nvidia-580-178-04 org.freedesktop.Platform.GL32.nvidia-580-178-04
  ```
  Replace `580-178-04` with your driver version from `nvidia-smi`, with dots turned into dashes.
  Repeat this after every NVIDIA driver update.
- **Hide its fan pages** (the KDE page is the combined view):
  `flatpak run --command=gsettings io.missioncenter.MissionCenter set io.missioncenter.MissionCenter performance-show-fans false`
- Mission Center can't attach fan readings to its GPU or CPU pages. That's why the
  KDE "GPUs & Cooling" page exists.

---

## 12. Uninstall everything

```bash
sudo systemctl disable --now p620-fans
sudo rm /etc/systemd/system/p620-fans.service /usr/local/sbin/p620-fans /etc/p620-fans.conf
sudo systemctl daemon-reload
echo 2 | sudo tee /sys/class/hwmon/hwmon*/pwm[14567]_enable        # back to firmware curves
sudo rm /etc/sensors.d/p620-nct6686.conf
sudo dkms remove nct6687d/1 --all && sudo rm -rf /usr/src/nct6687d-1
sudo rm /etc/modules-load.d/nct6687.conf /etc/modprobe.d/nct6687.conf
sudo rm /etc/default/grub.d/99-nct6687.cfg && sudo update-grub       # or undo §5b for your bootloader
sudo rm $(find /usr/lib /usr/lib64 -name ksystemstats_plugin_p620.so 2>/dev/null)   # Qt5 or Qt6 plugin folder
systemctl --user disable p620-cooling-page.service
rm ~/.config/systemd/user/p620-cooling-page.service ~/.local/bin/p620-cooling-page
rm ~/.local/share/plasma-systemmonitor/p620-cooling.page
```

> Warning: with the firmware back in control, the DIMM headers (P100 fans) drop to 0 % at
> idle. Passive P100s then reach about 80 °C under any load. Don't run GPU work without p620-fans.
