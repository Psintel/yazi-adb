# Fork updates
## What broke on Yazi 26.9.x
- `ui.Table` was removed → the file listing failed to render
- `Border`'s `type` field was replaced by `Border:set { as = ... }`
- `cx.active.selected` layout changed → pushed paths resolved to garbage ("cannot stat '1'")

## Changes
- Rewrote the renderers on `ui.Text`/`ui.Line`/`ui.Span`
  (manual scrolling, cursor highlight, status in the border title)
- Migrated `Border` to `:set { as = ... }`, added the title to both views
- `P` now pushes the native Yazi selection (falls back to the hovered
  file), with per-file progress and error reporting

Tested on Yazi 26.9.1 (Linux) against a Xiaomi/HyperOS device.

# yazi-adb

An Android device (`adb`) explorer plugin for [Yazi](https://yazi-rs.github.io/).

Browse, pull, push, and delete files on connected Android devices from
inside Yazi. If more than one device is attached, you get a device picker
first; with exactly one device, it drops you straight into the browser.

This is **not** a native Yazi virtual filesystem — Yazi's `cd`/tabs/copy
machinery has no concept of `adb://`. This plugin renders its own file
browser as a popup and drives `adb` itself for every operation. See
[ARCHITECTURE.md](ARCHITECTURE.md) for why, and for the internals in
general.

## Requirements

- [`adb`](https://developer.android.com/tools/adb) on `PATH`
- Yazi 26.5.6 or newer (untested on older versions)

## Installation

Clone (or symlink) this repository as `adb.yazi` under your Yazi plugins
directory:

```sh
git clone <this-repo-url> ~/.config/yazi/plugins/adb.yazi
```

(macOS/Linux path shown; on Windows it's
`%AppData%\yazi\config\plugins\adb.yazi`.)

## Setup

Add a keybinding in `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on  = "A"
run = "plugin adb"
desc = "Browse an Android device over adb"
```

Pick whatever key doesn't collide with your existing bindings.

Optionally configure the starting path on a device, in
`~/.config/yazi/init.lua`:

```lua
require("adb"):setup {
	default_path = "/sdcard", -- default is "/"
}
```

Starting at `/` (the default) means you'll likely hit permission-denied on
your first `cd` into a system directory — that's expected, see the root
retry behavior below.

## Usage

Press your bound key. With one device attached, you're in the browser
immediately. With more than one, pick a device first.

| Key | Alt | Action |
| --- | --- | --- |
| <kbd>j</kbd> | <kbd>↓</kbd> | Move down |
| <kbd>k</kbd> | <kbd>↑</kbd> | Move up |
| <kbd>l</kbd> / <kbd>Enter</kbd> | <kbd>→</kbd> | Enter directory (device list: pick device) |
| <kbd>h</kbd> | <kbd>←</kbd> / <kbd>Backspace</kbd> | Parent directory (bubbles up to device list at `/`, if more than one device) |
| <kbd>p</kbd> | - | Pull the hovered remote entry into the active Yazi tab's current directory |
| <kbd>P</kbd> | - | Push the file/directory selected in Yazi tab into the current remote directory |
| <kbd>d</kbd> | - | Delete the hovered remote entry (`adb shell rm -rf`, after confirmation) |
| <kbd>r</kbd> | - | Request root (`adb -s <id> root`) and reload |
| <kbd>R</kbd> | - | Refresh the current listing |
| <kbd>q</kbd> | <kbd>Esc</kbd> | Quit |

### Permission denied → root retry

Any operation (list/pull/push/delete) that fails with `Permission denied`
prompts:

> Retry as root on `<device>`? This runs `adb -s <device> root`.

Confirming runs `adb -s <device> root`, waits for the daemon to come back,
and retries the operation once. If the device's build doesn't support root
(most production/user builds), you'll get a clear error instead of a silent
hang.

## Known limitations

- `ls -la` output parsing assumes the toybox `ls` shipped since Android 6.
  Very old devices may parse less accurately. See ARCHITECTURE.md.
- No multi-select; operations act on the single hovered entry.
- Host-side path joining assumes POSIX (`/`); untested on a Windows host.

## Development

```sh
lua test.lua   # offline unit tests for adb.lua, no device/Yazi required
```

See [ARCHITECTURE.md](ARCHITECTURE.md) before making changes, especially
before touching state handling in `main.lua` — there's a non-obvious sync/
async split that's easy to get subtly wrong.

## License

MIT — see [LICENSE](LICENSE).
