<img src="linux/pantrace.png" width="84" align="left" alt="">

# Pantrace

[![CI](https://github.com/PanterSoft/Pantrace/actions/workflows/ci.yml/badge.svg)](https://github.com/PanterSoft/Pantrace/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/PanterSoft/Pantrace)](https://github.com/PanterSoft/Pantrace/releases/latest)
![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20macOS%20%7C%20Linux-blue)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Open-source CAN bus tracer with DBC decoding — the 10 % of CANoe most people
actually use: watch the bus, name the messages, read the signals, poke a frame
back. One Flutter codebase, no native plugin code.

## Features

- **Grouped view** — one row per id with count, cycle time and per-byte change
  highlighting (the CANoe "fixed" trace)
- **Live view** — frame-by-frame log, newest first
- **DBC decoding** — expand a message to see its signals inline, scaled, with
  units, value tables and multiplexing resolved
- **Filtering** — hex ids and ranges (`100, 200-2FF`), or DBC-known only
- **Send** — raw frames, 11/29-bit, RTR
- **Export** — CSV of the trace buffer, plus frames/s and bus load stats
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

Windows, Linux and the plain macOS dmg: grab the installer from the
[latest release](https://github.com/PanterSoft/Pantrace/releases/latest).

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

Linux also needs `ninja-build libgtk-3-dev`.

Not here yet: CAN FD, signal-level transmit composer, disk logging beyond CSV,
graphing.

## License

MIT
