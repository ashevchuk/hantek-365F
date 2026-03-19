# Hantek 365C/D/E/F — Linux Tools

Open-source Linux tools for the **Hantek 365C**, **Hantek 365D**, **Hantek 365E** and **Hantek 365F** true-RMS multimeters.

The device connects over USB-dongle and presents itself as a standard CDC-ACM serial port — no proprietary drivers needed:
0451:16aa Texas Instruments, Inc. TI CC2540 USB CDC

Two independent tools are provided:

| Tool | Language | Description |
|------|----------|-------------|
| `hantek365.pl` | Perl | Command-line reader with CSV/timestamp output |
| `hantek365_gui/` | C++ / Qt 6 | Desktop GUI with real-time chart and mode switching |

---

## Table of Contents

- [Screenshots](#screenshots)
- [Hardware](#hardware)
- [Protocol Overview](#protocol-overview)
- [Perl CLI Tool](#perl-cli-tool)
  - [Requirements](#requirements-perl)
  - [Usage](#usage)
  - [Examples](#examples)
  - [Output Formats](#output-formats)
- [Qt GUI Application](#qt-gui-application)
  - [Requirements](#requirements-qt)
  - [Building](#building)
  - [Running](#running)
  - [Interface](#interface)
  - [Responsive Layout](#responsive-layout)
- [Packet Format Reference](#packet-format-reference)
  - [Commands](#commands)
  - [Measurement Packet](#measurement-packet)
  - [Mode Codes](#mode-codes)
- [Permissions](#permissions)
- [License](#license)

---

## Screenshots

### GUI — Full View

![GUI full view](docs/screenshots/gui_full.png)

*Real-time voltage chart with mode buttons, toolbar, and statistics bar.*

### GUI — Compact Mode (toolbar and chart only)

![GUI compact](docs/screenshots/gui_compact.png)

*Window resized below 400 px height: mode panel automatically hide.*

### GUI — Minimal Mode (value only)

![GUI minimal](docs/screenshots/gui_minimal.png)

*Window resized below 140 px height: only the current measurement remains — useful as a small floating widget.*

### CLI Tool

```
./hantek365.pl -p /dev/ttyACM0 -m VDC -t

Setting mode: VDC (0xa0)
Mode set.
Reading measurements. Press Ctrl+C to stop.
2026-03-19 15:23:33 | +034.6 mV  DC AUTO
2026-03-19 15:23:33 | +015.2 mV  DC AUTO
2026-03-19 15:23:34 | +015.2 mV  DC AUTO
2026-03-19 15:23:35 | +015.3 mV  DC AUTO
2026-03-19 15:23:35 | +015.2 mV  DC AUTO
2026-03-19 15:23:36 | +009.7 mV  DC AUTO
2026-03-19 15:23:36 | +017.3 mV  DC AUTO
```

*Perl script reading DC voltage with timestamps.*

---

## Hardware

| Property | Value |
|----------|-------|
| Supported models | Hantek 365C, Hantek 365D, Hantek 365E, Hantek 365F |
| USB connection | Texas Instruments, Inc. TI CC2540 USB CDC (virtual serial port) |
| USB VID:PID | `0451:16aa` |
| Linux device node | `/dev/ttyACM0` (or `ttyACM1`, …) |

The device requires no special kernel drivers on Linux — the standard `cdc_acm` module handles it.

---

## Protocol Overview

Communication uses a simple binary protocol over the virtual serial port.

### Request/Response cycle

```
Host → Device: [0x01, 0x0F]        poll for current reading
Device → Host: [0xAA]              no data available yet
Device → Host: [0xA0, …×14]       15-byte measurement packet
```

Polling is done every **200 ms**. A response is expected within one poll interval; if it is not received the host resets and retries automatically.

### Mode change

```
Host → Device: [0x03, MODE_BYTE]   set mode / sub-range step
Device → Host: [0xDD]              acknowledgement
```

For modes in the range `0xA0–0xE6` the host must **cycle through sub-ranges** starting from 0 up to the target nibble, waiting for `0xDD` after each step (50 ms between steps). Special modes `0xF0–0xF6` (diode, cap, continuity, temperature) are sent directly without cycling.

---

## Perl CLI Tool

### Requirements (Perl)

- Perl 5.10 or newer (standard on all Linux distributions)
- Modules used — all are part of Perl core: `POSIX`, `Fcntl`, `Getopt::Long`, `Time::HiRes`
- No CPAN modules required

### Usage

```
./hantek365.pl [options]

Options:
  -p, --port PORT       Serial port (default: /dev/ttyACM0)
  -m, --mode MODE       Set measurement mode before reading
  -r, --relative        Enable relative (REL) measurement
  -v, --verbose         Print raw packet bytes for debugging
  -t, --timestamp       Prefix each reading with HH:MM:SS.mmm
  -c, --csv             CSV output: timestamp,value,prefix,unit,flags
  -i, --interval MS     Minimum interval between readings in ms (0 = max speed)
  -h, --help            Show help and exit
```

**Available modes** (case-insensitive):

| Category | Mode names |
|----------|-----------|
| DC Voltage | `VDC` `60mVDC` `600mVDC` `6VDC` `60VDC` `600VDC` `800VDC` |
| AC Voltage | `VAC` `60mVAC` `600mVAC` `6VAC` `60VAC` `600VAC` |
| DC Current | `mADC` `60mADC` `600mADC` `ADC` |
| AC Current | `mAAC` `60mAAC` `600mAAC` `AAC` |
| Resistance | `ohm` `600ohm` `6kohm` `60kohm` `600kohm` `6Mohm` `60Mohm` |
| Special | `diode` `cap` `cont` `temp` `tempc` `tempf` |

If `-m` is omitted the script reads whatever mode the multimeter is already in.

### Examples

```bash
# DC voltage with timestamp
./hantek365.pl -m VDC -t

# Resistance to CSV file
./hantek365.pl -m ohm -c > resistance.csv

# Temperature (°C) once per second
./hantek365.pl -m temp --interval 1000

# AC voltage on a different port, with raw debug output
./hantek365.pl -p /dev/ttyACM1 -m VAC -v

# REL mode — all readings relative to the first
./hantek365.pl -m VDC -r -t

# Pipe into gnuplot or awk
./hantek365.pl -m VDC -c | awk -F, '{print $1, $2}'
```

### Output Formats

**Default** (human-readable):

```
+1.2345 mV   DC AUTO
+0.0023 V    DC AUTO
```

**With timestamp** (`-t`):

```
14:32:01.423  +1.2345 mV   DC AUTO
14:32:01.624  +1.2346 mV   DC AUTO
```

**CSV** (`-c`):

```
timestamp,value,prefix,unit,flags
14:32:01.423,1.2345,m,V,DC AUTO
14:32:01.624,1.2346,m,V,DC AUTO
```

The `value` column is the raw numeric value with the SI prefix still applied (e.g. `1.2345` with prefix `m` = 1.2345 mV). Multiply by the appropriate factor to obtain SI base units.

---

## Qt GUI Application

### Requirements (Qt)

| Dependency | Version |
|-----------|---------|
| CMake | ≥ 3.16 |
| C++ compiler | C++17 (GCC 9+ / Clang 10+) |
| Qt | 6.x |
| Qt modules | `Widgets`, `SerialPort`, `Charts` |

On Arch Linux:

```bash
sudo pacman -S qt6-base qt6-charts qt6-serialport cmake
```

On Ubuntu 24.04 / Debian 13:

```bash
sudo apt install qt6-base-dev qt6-charts-dev qt6-serialport-dev cmake
```

On Fedora:

```bash
sudo dnf install qt6-qtbase-devel qt6-qtcharts-devel qt6-qtserialport-devel cmake
```

### Building

```bash
cd hantek365_gui
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

The resulting binary is `hantek365_gui/build/hantek365_gui`.

### Running

```bash
./build/hantek365_gui
```

Or install system-wide:

```bash
sudo cmake --install build
```

### Interface

```
┌─────────────────────────────────────────────────────────────────────┐
│ Port: [/dev/ttyACM0 ▼] [⟳] [Connect]  [Clear]  [REL] [⏸ Pause]  [Modes ▲] │  ← Toolbar
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│                    +1.2345 mV   DC AUTO                             │  ← Value display
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ▲                                                                 │
│   │  ~~~~~~~~~~~~~~~~~~~                                            │
│   │ /                   \                                           │  ← Real-time chart
│   │/                     ~~~~~~~~~~~~~~                             │
│   └──────────────────────────────────────────────── ▶              │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│      Min: 1.230 mV   Max: 1.246 mV   Avg: 1.238 mV  | 4.8 rdg/s   │  ← Statistics
├─────────────────────────────────────────────────────────────────────┤
│ DC V:  [VDC✓][60mVDC][600mVDC][6VDC][60VDC][600VDC][800VDC]       │
│ AC V:  [VAC][60mVAC][600mVAC][6VAC][60VAC][600VAC]                 │  ← Mode panel
│ DC A:  [mADC][60mADC][600mADC][ADC]                                │
│ ...                                                                 │
└─────────────────────────────────────────────────────────────────────┘
```

**Toolbar controls:**

| Control | Description |
|---------|-------------|
| Port combo | Select serial port (populated from available system ports) |
| ⟳ | Refresh the port list |
| Connect / Disconnect | Toggle connection (single button) |
| Clear | Clear chart data and statistics |
| REL | Toggle relative measurement mode on the device |
| ⏸ Pause / ▶ Resume | Freeze/unfreeze data acquisition |
| Modes ▲ / ▼ | Show or hide the bottom mode panel |

**Behaviour on connect:**
- Auto-selects **VDC** mode 400 ms after connecting (enough time for the device to settle)
- Statistics timer starts, mode buttons become active

**Chart features:**
- Up to 500 data points stored (ring buffer)
- X axis: real-time clock (`hh:mm:ss`)
- Y axis: auto-scaling SI prefix (µ / m / k / M), updates as values change
- Click and drag to zoom (Rectangle rubber band)
- When measurement unit changes (e.g. V → Ω), chart is cleared automatically

**Statistics bar** (updated every 2 seconds):

```
Min: 1.230 mV   Max: 1.246 mV   Avg: 1.238 mV   |   4.8 rdg/s   |   245 points
```

### Responsive Layout

The window adapts as it is resized:

| Window height | Visible elements |
|--------------|-----------------|
| ≥ 400 px | Full UI: toolbar, value, chart, statistics, mode panel |
| 140–399 px | Toolbar + current value only |
| < 140 px | Current value only — minimal floating widget |

This allows using the application as a compact always-on-top widget while working in other applications.

---

## Packet Format Reference

### Commands

| Bytes | Description |
|-------|-------------|
| `01 0F` | Poll: request current measurement |
| `03 XX` | Set mode/sub-range (`XX` = mode code, see table below) |

### Measurement Packet

15 bytes, first byte is always `0xA0`.

```
Offset  Size  Description
──────  ────  ──────────────────────────────────────────────────────────
  0      1    Start marker: 0xA0
  1      1    Sign byte:  bit 2 = minus (−),  bit 1 = plus (+)
  2–5    4    ASCII digits of the displayed number (e.g. '1','2','3','4')
  6      1    Reserved (always 0x00)
  7      1    Decimal point position mask:
                 value = (byte − 0x30);  point inserted after digit i
                 where (mask >> i) == 1
                 0x30 = no decimal point
  8      1    Mode flags:
                 bit 3 (0x08) = AC
                 bit 4 (0x10) = DC
                 bit 5 (0x20) = AUTO range (else MANU)
                 bit 2 (0x04) = REL active
  9      1    Nano flag: bit 1 (0x02) = nano (n) prefix
 10      1    Multiplier prefix:
                 0x80 = µ (micro, ×1e-6)
                 0x40 = m (milli, ×1e-3)
                 0x20 = k (kilo,  ×1e+3)
                 0x10 = M (mega,  ×1e+6)
                 0x08 = continuity beep active (no SI prefix change)
 11      1    Unit of measurement:
                 0x01 = °F
                 0x02 = °C
                 0x04 = F  (capacitance)
                 0x20 = Ω  (resistance)
                 0x40 = A  (current)
                 0x80 = V  (voltage)
12–14   3    Unknown / reserved
```

**Special device responses:**

| Byte | Meaning |
|------|---------|
| `0xAA` | No data available (device not ready yet) |
| `0xDD` | Mode change acknowledged |

### Mode Codes

The high nibble selects the measurement category; the low nibble selects the sub-range.

```
Category       Codes      Ranges
──────────────────────────────────────────────────────────────
DC Voltage     A0–A6      AUTO, 60mV, 600mV, 6V, 60V, 600V, 800V
AC Voltage     B0–B5      AUTO, 60mV, 600mV, 6V, 60V, 600V
DC Current     C0–C3      AUTO(mA), 60mA, 600mA, AUTO(A)
AC Current     D0–D3      AUTO(mA), 60mA, 600mA, AUTO(A)
Resistance     E0–E6      AUTO, 600Ω, 6kΩ, 60kΩ, 600kΩ, 6MΩ, 60MΩ
Special        F0–F6      Diode, Cap, Continuity, -, -, Temp°C, Temp°F
```

**Mode change protocol** for categories A–E:

```
To set mode 0xA3 (6VDC):
  send [03 A0] → wait for DD
  send [03 A1] → wait for DD
  send [03 A2] → wait for DD
  send [03 A3] → wait for DD  ← target reached
```

Modes `0xF0–0xF6` (Special) are sent directly without sub-range cycling.

---

## Permissions

The device node `/dev/ttyACM0` is owned by the `dialout` group. Add your user to that group to avoid running as root:

```bash
sudo usermod -aG dialout $USER
```

Log out and back in (or run `newgrp dialout`) for the change to take effect.

Verify:

```bash
ls -l /dev/ttyACM0
# crw-rw---- 1 root dialout 166, 0 ...

id | grep dialout
# should show dialout in the list
```

---

## Project Structure

```
.
├── hantek365.pl          Perl command-line utility
├── hantek365_gui/
│   ├── CMakeLists.txt
│   ├── main.cpp          Application entry point, dark theme setup
│   ├── mainwindow.h      Main window declaration
│   ├── mainwindow.cpp    Main window implementation (UI, chart, slots)
│   ├── hantekdevice.h    Device abstraction (signals/slots interface)
│   └── hantekdevice.cpp  Serial port state machine, packet parser
└── docs/
    └── screenshots/      Screenshots for this README
```

---

## License

This project is released under the **MIT License**.

```
Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
