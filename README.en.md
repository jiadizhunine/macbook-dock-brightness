<div align="center">

**English** | [简体中文](./README.md)

</div>

<h1 align="center">MacBook Dock Brightness</h1>

<p align="center">
  <b>Dim the built-in MacBook display when your chosen monitor connects, then restore brightness and automatic brightness when it leaves</b><br>
  <i>A tiny, source-only macOS display policy for open-lid desk setups.</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v0.1.0-blue" alt="Version">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="Platform">
  <img src="https://img.shields.io/badge/distribution-source--only-purple" alt="Source only">
</p>

## What it solves

You want to keep a MacBook open for its keyboard, trackpad, Touch ID, camera, and speakers while looking only at a large external display.

When the **external display you explicitly selected and confirmed** is online, active, and mirrored with the built-in display, MacBook Dock Brightness:

- turns off automatic brightness for the built-in display;
- sets its hardware brightness to `0%`;
- attempts to restore the configured brightness and automatic brightness when the monitor disconnects, the service stops normally, or the tool is uninstalled.

It does not trigger for every external display. Installation requires an explicit choice from a read-only display list; confirm that the selected target is not AirPlay or a virtual display. Persistent matching uses vendor/model and can optionally include its serial number.

## Important boundary

This tool sets the built-in backlight to zero; it does **not truly disconnect the display**. The built-in display remains in the macOS display topology, so:

- You must enable mirroring in System Settings → Displays first. The tool refuses to dim the built-in display in extended-desktop mode.
- Do not expect framebuffer release, lower GPU use, or a performance increase.
- It uses undocumented Apple CoreBrightness/DisplayServices interfaces. A macOS update may break them. Before entering the dark state, unsupported, ambiguous, or unverified states are rejected. If restoration APIs fail after the display is already dark, use the brightness key or `--restore` recovery path below.

The hardware-tested configuration is an **M5 MacBook Air running macOS 27.0 beta (build 26A5406e) with an LG 4K USB-C display**. Other Macs and macOS versions may be attempted from source, but remain unverified and unsupported.

## Install

Requirements:

- a MacBook with a physical external display connected;
- mirroring enabled between the two displays;
- Xcode Command Line Tools: `xcode-select --install`;
- your normal login account, without `sudo`.

```bash
git clone https://github.com/jiadizhunine/macbook-dock-brightness.git
cd macbook-dock-brightness
make check
./build/macbook-dock-brightness --list-displays
./scripts/install.sh --target-display-id 3 --undocked-brightness 0.32
```

The installer compiles the source locally and never guesses a target display. Replace `3` with the ID of the target already mirrored with the built-in display.

After launch, the installer also verifies that the LaunchAgent stays running and that status can be read back. If a fresh install or upgrade fails this health check, it stops the new service, restores the built-in display, and rolls back the previous files and service state.

`--target-display-id` is used only to read the monitor identity during installation; the transient CoreGraphics ID is not persisted. Add `--match-serial` when more than one display has the same vendor and model and the display reports a non-zero serial.

Installed files:

| Path | Purpose |
| --- | --- |
| `~/Library/Application Support/MacBookDockBrightness/` | Locally built executable, configuration, and recovery state |
| `~/Library/LaunchAgents/io.github.jiadizhunine.macbook-dock-brightness.plist` | Starts the monitor after login |
| `~/Library/Logs/MacBookDockBrightness*.log` | Low-frequency event and error logs |

## Use and inspect

List displays:

```bash
./build/macbook-dock-brightness --list-displays
```

Inspect the target, mirror relationship, brightness, and automatic brightness:

```bash
"$HOME/Library/Application Support/MacBookDockBrightness/macbook-dock-brightness" --status
```

Preview the next action without changing settings:

```bash
"$HOME/Library/Application Support/MacBookDockBrightness/macbook-dock-brightness" --dry-run
```

Configuration is stored at:

```text
~/Library/Application Support/MacBookDockBrightness/config.json
```

The default policy is `0% + automatic brightness off` while docked and `32% + automatic brightness on` after disconnecting. Once the state has been verified and no new display or wake event occurs, the two-second watchdog only enumerates online displays and does not rewrite brightness.

## Uninstall and emergency recovery

From the repository directory:

```bash
./scripts/uninstall.sh
```

The uninstaller stops the background service, verifies that the built-in display was restored, and only then removes the executable and configuration. Logs are retained unless requested:

```bash
./scripts/uninstall.sh --purge-logs
```

If the built-in display unexpectedly remains dark, press the MacBook brightness-up key or run:

```bash
MDB_SERVICE_TARGET="gui/$(id -u)/io.github.jiadizhunine.macbook-dock-brightness"
launchctl bootout "$MDB_SERVICE_TARGET" 2>/dev/null || true
if launchctl print "$MDB_SERVICE_TARGET" >/dev/null 2>&1; then
  echo "The background service is still running; keep the recovery files."
else
  "$HOME/Library/Application Support/MacBookDockBrightness/macbook-dock-brightness" --restore
fi
```

Do not disable Gatekeeper or run an untrusted `xattr` command for this project.

If the configuration is damaged or missing, `--restore` uses a safe fallback: `32%` built-in brightness with automatic brightness enabled.

## Hand it to an AI coding agent

You can give a local coding agent this prompt:

> Read `README.en.md` and `AGENTS.md` completely, run `make check`, then run `./build/macbook-dock-brightness --list-displays` read-only. Show me the external target, mirror status, and restore brightness for confirmation before installing. Do not use sudo, disable Gatekeeper, or install a prebuilt binary.

## How it works

- Objective-C with ARC, using the system AppKit, CoreGraphics, and Foundation frameworks.
- CoreGraphics callbacks, AppKit screen-parameter notifications, and wake notifications provide the primary triggers.
- A two-second watchdog only fills missed event gaps and uses retry backoff.
- Every brightness and automatic-brightness write is read back for verification.
- Managed recovery state is written before dimming. Disconnect, SIGTERM, SIGINT, and uninstall all use the restoration path.
- The LaunchAgent starts at login without `KeepAlive`; if a system update makes a private API crash, the process does not enter a restart loop.
- It runs locally with no network access or telemetry and requires no administrator, Accessibility, Screen Recording, or Input Monitoring permission.

## Source-only distribution

GitHub Releases contain source code only, with no compiled executable attached. Each user can inspect and compile the project on their own Mac, so there is no downloaded, unnotarized third-party binary and no reason to bypass Gatekeeper.

CI can validate compilation, static analysis, configuration, scripts, and non-mutating CLI behavior. Real hot-plug, sleep/wake, and private-API behavior still require a physical MacBook.

## Related projects

- [OpenClamshell](https://github.com/strohsnow/OpenClamshell): mirror and dim the built-in display.
- [clamOpen](https://github.com/Attiv/clamOpen): soft-disable the built-in display through private CoreGraphics APIs.
- [ExternalDisplayOnly](https://github.com/ilyasaftr/ExternalDisplayOnly): automatically soft-disconnect and restore the built-in display.

This is an independent implementation focused on a chosen external display, automatic-brightness restoration, and preserving the mirror topology.

## License

[MIT](./LICENSE). This is not an official Apple or LG product and is not endorsed by either company.
