# vscreen

An invisible virtual display for macOS, so an agent can run a GUI app, take screenshots and measure frame rates without raising a window on your screens.

> [!WARNING]
> vscreen uses `CGVirtualDisplay`, a private CoreGraphics API (the same one Chromium and DeskPad use). Apple can change or remove it in any macOS release.

## Why

A window covered by other windows, or on a hidden Space, is throttled by macOS: frame and CPU numbers come out wrong. Raising it on your screens interrupts your work. A virtual display is invisible to you, and WindowServer draws it at full rate.

## Install

Needs Xcode command line tools.

```bash
git clone https://github.com/0xCaso/vscreen
cd vscreen
PREFIX=~/.local/bin ./build.sh
```

`vscreen launch` loads `libvscreen_place.dylib` from the folder of the `vscreen` binary; set `VSCREEN_PLACE_DYLIB` to load it from elsewhere.

## Usage

```bash
vscreen ensure > display.json                                        # shared display, started once and reused
vscreen launch --name shared --log app.log -- path/to/App.app        # windows open on the virtual display
vscreen shot --name shared --pid <pid> --out shot.png
kill <pid>                                                           # leave the shared display running
```

Each `create` and `destroy` is a display change: window managers that park hidden windows (Spaceman, for one) move them again, and macOS can flash them on your screen. `ensure` starts one long-lived display named `shared` in its own session and returns it to every later caller, so a day of agent runs makes one display change. Use `create`/`destroy --name <n>` only when you need a private display (another size, or an empty screen for an fps measurement).

| Command | What it does |
|---|---|
| `ensure` | Returns the shared display, or starts it detached so it outlives the caller. JSON includes `reused` |
| `create` | Creates a private display, prints JSON, runs until `destroy` or SIGTERM |
| `launch` | Starts an app with its windows on the virtual display and activation disabled. No Accessibility permission. Not for hardened-runtime or Apple apps |
| `move` | Moves a running app's windows onto the display (needs Accessibility) |
| `shot` | Captures the app's window with `screencapture -l` |
| `windows`, `list` | Lists an app's windows, or the active and virtual displays |
| `destroy` | Stops the display and checks it is gone |

`build/fpsprobe` is a test window that logs its frames per second.

## License

[MIT](LICENSE)
