<img src="linux/pantrace.png" width="84" align="left" alt="">

# Pantrace

[![CI](https://github.com/PanterSoft/Pantrace/actions/workflows/ci.yml/badge.svg)](https://github.com/PanterSoft/Pantrace/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/PanterSoft/Pantrace)](https://github.com/PanterSoft/Pantrace/releases/latest)
![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20macOS%20%7C%20Linux-blue)
![Architectures](https://img.shields.io/badge/arch-x64%20%7C%20arm64-blue)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Open-source CAN bus tracer with DBC decoding — the 10 % of CANoe most people
actually use: watch the bus, name the messages, read the signals, poke a frame
back. One Flutter codebase, no native plugin code.

## Features

- **Two channels** — CAN1 and CAN2 on independent interfaces and bitrates,
  traced side by side with a CH column; the same id on both buses lands on
  adjacent rows, so gateway forwarding is easy to compare
- **Grouped view** — one row per id with count, cycle time and per-byte change
  highlighting (the CANoe "fixed" trace); click a column header to sort, click
  again to flip
- **Error frames** — shown in red in the live view, counted in the status bar
- **Live view** — frame-by-frame log, newest first
- **DBC decoding** — expand a message to see its signals inline, scaled, with
  units, value tables and multiplexing resolved
- **Filtering** — hex ids and ranges (`100, 200-2FF`), or DBC-known only
- **Time modes** — click the live view's TIME header for absolute, relative to
  measurement start, or delta to the previous frame
- **Send** — raw frames, 11/29-bit, RTR; or pick a DBC message and type
  physical signal values (value-table names work too)
- **Cyclic transmit** — give Send a cycle time and the frame repeats; the
  transmit list (⟳ in the toolbar) pauses, resumes and removes them
- **Record** — streams every frame to disk, independent of pause, filter and
  the view's buffer, as any of the formats below. MF4 recordings are flagged
  unfinalised until stopped, so a crash still leaves a recoverable file
- **Log files** — open a log into the trace (offline analysis), replay one onto
  the connected buses with its original timing (0.25×–10×, loop, channel
  mapping), or export the trace buffer
- **Statistics** — frames/s and per-channel bus load
- **Share** — re-expose whatever adapter is connected as an SLCAN device, so
  python-can, SavvyCAN, cangaroo or `slcand` use it alongside Pantrace:
  `socket://127.0.0.1:20100` on every OS, plus a virtual serial port
  (`/dev/ttys…`, shown in the status line) on macOS and Linux. Frames go both
  ways; the bitrate stays Pantrace's.

## Install

macOS, via Homebrew:

```sh
brew tap pantersoft/pantersoft
brew trust --cask pantersoft/pantersoft/pantrace   # once: third-party casks are untrusted
brew install --cask pantrace
```

The build is ad-hoc signed, not notarised, so macOS quarantines it. If it
refuses to open: `xattr -dr com.apple.quarantine /Applications/Pantrace.app`.

Everything else is on the
[latest release](https://github.com/PanterSoft/Pantrace/releases/latest):

| OS | x64 (Intel/AMD) | arm64 |
| --- | --- | --- |
| Windows 10/11 | `Pantrace-windows-x64-setup.exe` or `-portable.zip` | `Pantrace-windows-arm64-setup.exe` or `-portable.zip` |
| macOS 12+ | `Pantrace-macos.dmg` (universal) | same |
| Debian, Ubuntu | `Pantrace-linux-amd64.deb` | `Pantrace-linux-arm64.deb` |
| Fedora, openSUSE, RHEL | `Pantrace-linux-x86_64.rpm` | `Pantrace-linux-aarch64.rpm` |
| Other Linux | `Pantrace-linux-x64.tar.gz` | `Pantrace-linux-arm64.tar.gz` (Raspberry Pi 4/5 with a 64-bit OS) |

No hardware? Pick **Demo traffic generator**, hit Connect, then **Load DBC** →
`example/demo.dbc`.

## Hardware

| Backend | Devices | OS | Bound via |
| --- | --- | --- | --- |
| SLCAN | CANable, CANtact, USBtin, Lawicel CAN232, most cheap USB-CAN sticks | all | libserialport, bundled |
| SocketCAN | any Linux CAN driver, `vcan`, gs_usb, PEAK, Kvaser… | Linux | `dart:ffi` → libc |
| PCAN | PCAN-USB, -PCI, -LAN | all | `dart:ffi` → `PCANBasic.dll` / `libpcanbasic.so` / `libPCBUSB.dylib` |
| Vector XL | VN1610/1630, CANcaseXL, VN8900… | Windows | `dart:ffi` → `vxlapi64.dll` |
| Virtual | demo generator, loopback | all | — |

Vendor backends bind to the driver the vendor already installs — nothing to
compile. A missing driver library just means that backend lists no devices, and
the status line says what to install.

<details>
<summary>Driver notes</summary>

- **PCAN Windows/Linux** — install the PEAK driver package; it ships PCANBasic.
- **PCAN macOS** — install [MacCAN PCBUSB](https://mac-can.github.io/), which
  exposes the PCANBasic API as `libPCBUSB.dylib`.
- **Vector** — install the XL Driver Library and assign channels in *Vector
  Hardware Config*; Pantrace lists application-channel indices 0-7.
- **SocketCAN** — a down link is brought up with
  `ip link set canX up type can bitrate N`, which needs root: run it yourself
  first or start the app with `sudo`.
- **SLCAN** — only ports answering the `V` query with SLCAN framing are listed,
  plus known adapters by USB descriptor; Bluetooth and debug consoles are never
  probed. Toggle **All ports** for firmware that doesn't answer `V`. Bitrates
  come from the fixed S0–S8 table (10k–1M).
- **Virtual SLCAN** — a program emulating an SLCAN adapter on a pseudo-terminal
  is listed when it links the pty as `/tmp/slcan*` (e.g. a network-to-CAN
  bridge). Pantrace opens it directly, since libserialport can't open ptys.
- **Sharing a channel** — SocketCAN, Vector XL and PCAN (Windows/Linux) let
  Pantrace run next to CANoe, PCAN-View etc. on the same channel; whoever
  opened it first sets the bitrate. For everything else, see *Share* below.

</details>

## Build

```sh
make test     # no hardware needed
make run      # picks macos / linux / windows from the host; override with OS=
make build    # release bundle into build/<os>/
```

Linux also needs `ninja-build libgtk-3-dev`. Packages from a Linux build:
`linux/package-deb.sh <version> [x64|arm64]` and `linux/package-rpm.sh …`.

Not here yet: CAN FD, signal graphing.

## Log formats

Read and written, checked against python-can and asammdf in both directions:

| Format | Extension | Written by / read by |
| --- | --- | --- |
| Vector BLF | `.blf` | CANoe, CANalyzer (native log), python-can |
| Vector ASC | `.asc` | CANoe, CANalyzer, SavvyCAN, python-can |
| ASAM MDF 4.1 | `.mf4` `.mdf` | CANape, CANoe, asammdf, CANedge — standard CAN bus-logging layout; reads DT/DZ/DL/HL data, sorted and unsorted |
| candump | `.log` | Linux can-utils (`candump -l`, `canplayer`), python-can |
| PCAN trace | `.trc` | PCAN-View (writes 2.1, reads 1.x and 2.x) |
| CSV | `.csv` | spreadsheets |

## CI/CD

Every push and pull request runs analysis and the tests on Linux, macOS and
Windows, then builds release packages natively on each OS and CPU:

| OS | x64 | arm64 | Packages |
| --- | --- | --- | --- |
| Linux | `ubuntu-latest` | `ubuntu-24.04-arm` | `.deb`, `.rpm`, `.tar.gz` |
| Windows | `windows-latest` | `windows-11-arm` (experimental) | installer, portable `.zip` |
| macOS | universal binary on `macos-latest` | ← same | `.dmg` |

A push to `main` bumps the version, tags it and publishes every package with a
`SHA256SUMS` file. The in-app updater downloads the installer matching the
machine's architecture.

## License

MIT
