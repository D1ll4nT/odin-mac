# odin-mac

A native macOS command-line tool for flashing firmware to Samsung devices in
Download Mode, over USB, with no drivers and no virtual machine.

It exists because Samsung never shipped a Mac version of Odin, and the existing
alternatives (Heimdall, the leaked Linux `odin4`) don't work reliably on modern
phones or modern macOS.

> [!WARNING]
> **This is a proof of concept. It has never been run against a real phone.**
> The entire flashing protocol was reconstructed by static analysis of the
> Windows Odin binary and cross-checked against Heimdall — but the actual
> write path has not been tested on hardware. **Flashing can permanently brick
> or wipe a device.** The first time you use `--yes`, use a phone you can
> afford to lose. No warranty; see [LICENSE](LICENSE).

## What it does

- Detects a Samsung device in Download Mode (`/dev/cu.usbmodem*`, filtered by
  Samsung's USB vendor ID).
- Performs the `ODIN`/`LOKE` handshake and reads the device partition table (PIT).
- Loads `BL` / `AP` / `CP` / `CSC` / `UMS` files in `.tar`, `.tar.md5`, and
  `.lz4` form; verifies the MD5 trailer; unpacks on the Mac.
- Maps every file to a PIT partition **before writing anything**, then flashes
  in Odin's slot order (BL → AP → CP → CSC → UMS) and reboots.

## What it does NOT do

- **No re-partitioning / PIT flashing.** A full `CSC_*` file carries a `.pit`
  and would re-partition the phone; this tool never sends the write-PIT command,
  so a full CSC is rejected. Use `HOME_CSC` (which also preserves your data).
- No NAND erase, no flash-lock changes, no GUI, no compressed-transfer path
  (files are decompressed on the host instead), no modem-destination path, and
  no support for devices below protocol v2.
- It is a firmware flasher only. It does not bypass FRP, account locks, or any
  other device-owner security.

## Requirements

- macOS 13+, Apple Silicon or Intel.
- [`lz4`](https://formulae.brew.sh/formula/lz4) for `.lz4` firmware:
  `brew install lz4`.

## Build

```sh
swift build -c release      # binary at .build/release/odin-mac
swift test                  # protocol, PIT, tar/md5/lz4, and a full fake-device session
```

## Use

Put the phone in Download Mode (power off; hold Vol-Down + Vol-Up while
plugging in USB; press Vol-Up to confirm) and connect it.

```sh
# 1. Detect + handshake + print the partition table. Writes nothing.
odin-mac

# 2. Verify, unpack, and show which partition each file maps to. Writes nothing.
odin-mac --dry-run --bl BL_*.tar.md5 --ap AP_*.tar.md5 --cp CP_*.tar.md5 --csc HOME_CSC_*.tar.md5

# 3. Actually flash. Requires --yes.
odin-mac --yes --bl BL_*.tar.md5 --ap AP_*.tar.md5 --cp CP_*.tar.md5 --csc HOME_CSC_*.tar.md5
```

Flags: `--port /dev/cu.usbmodemX` to pick a device, `--no-reboot` to stay in
Download Mode after flashing.

If a step fails mid-session the phone stays in Download Mode; re-enter it by
hand (hold Vol-Down + power to cancel) and retry.

## How it was built

The protocol was recovered from `Odin3 v3.13.3.exe` with a reverse-engineering
toolchain and cross-checked against [Heimdall](https://github.com/Benjamin-Dobell/Heimdall).
No Samsung code is included; this is a clean-room reimplementation for
interoperability. Odin and Samsung are trademarks of Samsung Electronics; this
project is not affiliated with or endorsed by Samsung.
