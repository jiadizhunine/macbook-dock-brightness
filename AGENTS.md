# AGENTS.md

This repository is intentionally source-only. Read `README.md` or
`README.en.md` before changing or running the installer.

## Build and validate

```bash
make check
```

The command must compile with warnings as errors, pass Clang static analysis,
run smoke tests, validate both shell scripts, and lint the LaunchAgent template.

## Safety invariants

- Never dim the built-in display unless exactly one configured external target
  is online, active, and mirrored with the built-in display.
- Treat an ambiguous target, invalid configuration, missing built-in display,
  or unavailable private API as fail-open: do not dim.
- Write managed recovery state before disabling automatic brightness or setting
  brightness to zero.
- Verify every brightness and automatic-brightness write by reading it back.
- If the dark-state transaction fails, restore the configured undocked state.
- On target disconnect, SIGTERM, SIGINT, or uninstall, attempt both brightness
  and automatic-brightness restoration even if one step fails.
- Keep the two-second watchdog lightweight. It may enumerate displays, but it
  must not continuously call private setters while the state is unchanged.
- Keep the LaunchAgent free of `KeepAlive` unless a persistent crash circuit
  breaker is implemented first; private-API ABI changes must not cause a loop.
- The installed daemon must never require `sudo`, Accessibility, Screen
  Recording, Input Monitoring, a network connection, or disabling Gatekeeper.

## Distribution rules

- Do not commit compiled binaries, generated user configuration, state files,
  logs, absolute home paths, or display serial numbers.
- GitHub Releases contain source only. Do not attach ad-hoc-signed binaries.
- Preserve the installer's verified rollback: stop the new job, restore the
  built-in display, and atomically restore the previous files before restarting
  an older job. Never restart either version while recovery is incomplete.
- Keep the Chinese and English READMEs consistent, especially commands,
  compatibility limits, recovery steps, and private-API warnings.
- The project uses private Apple APIs loaded at runtime. Do not claim App Store
  compatibility, true display disconnection, framebuffer release, GPU savings,
  or compatibility beyond hardware that has been tested.

## Main files

- `Sources/macbook-dock-brightness.m`: CLI, daemon, display policy, recovery.
- `scripts/install.sh`: local compilation and user LaunchAgent installation.
- `scripts/uninstall.sh`: stop, verified restoration, and removal.
- `LaunchAgent.plist.template`: generated with absolute user paths at install.
- `tests/smoke.sh`: non-destructive CLI and configuration smoke tests.
