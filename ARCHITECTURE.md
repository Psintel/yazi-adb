# Architecture notes

This file is for whoever (most likely: me, in a future session) picks this
project back up. It records the *why* behind decisions that aren't obvious
from the code, so they don't get re-litigated or accidentally undone.

## The constraint that shaped everything

Yazi's virtual filesystem is closed at the Rust layer. `yazi-vfs::Providers`
is a compile-time enum of exactly four backends: `Local`, `Search`,
`Archive`, `Sftp` (the last added via `vfs.toml`, still Rust-implemented).
There is no trait object, no registration hook, nothing a Lua plugin can
implement to back a fifth scheme. Confirmed by reading
`yazi-vfs`/`yazi-fs::engine::Provider` in the `sxyazi/yazi` source (checked
against the installed `26.5.6`).

Practical consequence: **`adb://<device-id>/<path>` is not a real Yazi URL.**
Core `cd`, `ls`, copy/paste, tabs — none of it knows this scheme exists. It's
purely this plugin's own internal addressing, used for display (the title
bar) and as the value threaded through `self.device`/`self.path`. Don't try
to feed it into `Url(...)`, `ya.emit("cd", ...)`, or any core command
expecting a real Yazi URL — it will not resolve.

Given that, the plugin is a **self-contained modal file browser**: it owns
listing, navigation, and transfer end-to-end by shelling out to `adb`, and
renders its own UI on top of Yazi's `Modal` layer. This mirrors how
`yazi-rs/plugins`' `mount.yazi` handles disk mount/unmount/eject — that
plugin was the concrete template this codebase was built from (see below).

## Why it looks like `mount.yazi`

`mount.yazi`'s `main.lua` (from `yazi-rs/plugins`) is the one working,
real-world example of a plugin that:

- Registers a persistent overlay via `Modal:children_add(self, order)`
- Runs a `producer`/`consumer` coroutine pair joined with `ya.join`, where
  the producer calls `ya.which { cands = self.keys, silent = true }` in a
  loop as the *generic keyboard-input reader* for a custom modal (not just a
  bounded picker — this is the important realization: `ya.which` with
  `silent = true` is how plugins build arbitrary interactive key-loops)
- Renders a `ui.Table` inside a `ui.Border` inside a centered `ui.Layout`
  split

This plugin follows that shape almost exactly, with the mount/unmount/eject
actions swapped for enter-dir/pull/push/delete/root, and the partition list
swapped for either a device list or a directory listing depending on
`self.mode`.

## The sync/async split — read this before changing state handling

`M:entry()`, and everything the producer/consumer coroutines call, run in an
**isolated async Lua context**. `M:redraw()`, `M:new()`, and every
`ya.sync(function(self) ... end)` callback run in the **sync (main-thread)
context**, against the one persistent, canonical `self` table for this
plugin instance.

These are not the same `self`. Verified by reading
`yazi-plugin/src/utils/sync.rs`: `ya.sync()` compiles a callback into a
message that gets dispatched via `AppProxy::plugin(...)` to the sync
context, where it's executed against a table fetched fresh via `LOADER`, and
the return value is marshaled back across an mpsc channel as `Data` (a
serializable value type — not a raw table reference). Async code that reads
`self.foo` directly is reading whatever that async invocation's *own* copy
of the module table holds, which does not track mutations made by sync
setters.

Consequence: **every piece of state that's mutated by a sync setter must
also be read back through a dedicated sync getter**, even from within the
same plugin's async code. Search this codebase for `get_mode`, `get_device`,
`get_path`, `get_default_path`, `active_device`, `active_entry`,
`device_count` — those exist for exactly this reason. The only field safely
read directly in async code is `self.keys`, because it's a static literal
that's identical in both contexts (this matches `mount.yazi`, which reads
`self.keys` directly but wraps `self.partitions`/`self.cursor` access in
`active_partition()`).

If you add new mutable state, add a getter. Don't shortcut this even though
it looks like the async code "already has `self`" — it does, just not the
one you want.

## Why `M.root()` polls `get-state` instead of `wait-for-device`

`adb -s <id> wait-for-device` blocks with no timeout. If the device never
comes back (build doesn't support root, USB hiccup, whatever), the plugin
would hang forever with no way for the user to escape short of killing
Yazi. Polling `adb -s <id> get-state` every 0.5s for ~10s and giving up with
an error is strictly worse in the happy path (slightly slower) and strictly
better in the failure path (bounded).

## Why shell commands are built as one pre-quoted string

`adb shell <args...>` does not reliably preserve argv boundaries across the
USB/network transport for all adb/device combinations — several adb
versions rejoin the arguments with spaces and hand the result to
`/system/bin/sh -c` on the device side. Passing `path` as a separate
`Command:arg()` element is therefore not safe against spaces or shell
metacharacters in filenames.

Instead, `adb.lua` builds the *entire* remote command as one string with our
own POSIX quoting (`M.quote`, single-quote wrapping with `'\''` escaping for
embedded quotes) and passes that single string as the one argument after
`shell`. This is the same reason `--` is inserted before the path argument
in `ls`/`rm` — defends against filenames that start with `-` being parsed as
options by the remote `ls`/`rm`.

This does mean: if a filename contains a literal single quote, it's handled
by the escaping above and covered by a test in `test.lua`. If you touch
`M.quote`, keep that test green.

## Nested prompts (`ya.confirm` inside the `producer`/`consumer` loop)

Found by live testing against a real device, not by reading the source —
worth knowing because it doesn't show up any other way.

`producer()` sits in a tight loop on `ya.which { silent = true }`, which
is *the* input sink for as long as one call is outstanding. Calling
`ya.confirm` from `consumer()` (e.g. inside `maybe_offer_root`, or the
delete confirmation) while `producer()`'s `ya.which` is still pending does
**not** transfer keyboard input to the new prompt — the confirm dialog
rendered on screen correctly, but every keystroke was a silent no-op.
Confirmed live: pressed `y`/`n`/`<Esc>` repeatedly against a real "retry as
root?" prompt with none of them registering, and it un-froze the instant
the fix below was in place.

`mount.yazi` hits the identical class of problem for its sudo-password
prompt (`sudo.lua`/`cross.lua`) and solves it with a permit handshake:

1. Hand a single-buffered `mpsc` channel a token.
2. `ya.emit("which:dismiss", {})` — force-cancels the outstanding
   `ya.which`.
3. `producer()`'s own post-`ya.which` `permit_tx:send(true)` now blocks,
   because the channel (capacity 1) is already holding the token from
   step 1 — this is what actually parks `producer()` for the duration.
4. Do the nested prompt.
5. `permit_rx:recv()` drains the channel, which both unblocks
   `producer()`'s parked send and hands the loop back to it.

This plugin uses the same handshake (`with_input_paused` in `main.lua`),
wrapped around both `ya.confirm` call sites. If you add a third nested
prompt (another `ya.confirm`, or `ya.input`), wrap it the same way — don't
call it directly from `consumer()`.

## `ls -la` parsing is inherently a little fragile

There's no structured `adb shell` output format for directory listings —
we're scraping `ls -la` text. This assumes the toybox `ls` that's been the
AOSP default since Android 6 (Marshmallow): permissions, links, owner,
group, size, date, time, name, with symlinks rendered as `name -> target`.

Known limitations, not yet handled:
- Very old devices with BusyBox/toolbox `ls` may format columns differently
  (e.g. no group column — there's a fallback regex for that one case, but
  not for every historical variant).
- Locale-dependent date formatting is not accounted for.
- Filenames containing embedded newlines will break line-splitting (rare in
  practice, `ls` itself has the same problem).

If this becomes a real problem, the fix is almost certainly switching to
`find <path> -maxdepth 1 -printf` (GNU-find-style, not always present on
Android) or per-entry `stat -c`, at the cost of more round-trips. Not worth
it until it's an actual reported issue.

## State machine

```
        (no devices)
             |
             v
  [entry()] -+-> (exactly one device) --------------------+
             |                                              v
             +-> (>1 device) --> mode = "devices" --> mode = "browser"
                                       ^                     |
                                       |   "back" at "/"      |  "back" navigates to
                                       +----------------------+  adb.parent(path); at "/"
                                                                   with >1 device, pops
                                                                   back to "devices"
```

`self.mode` is the only thing `redraw()` branches on. Both modes reuse the
same `Modal` component, the same `keys` table, and the same producer/
consumer loop — only the meaning of "enter"/"up"/"down"/"back" changes based
on `get_mode()`.

## Things deliberately left out of v1 (not oversights)

- **Multi-select.** Yazi's own selection model isn't reachable from a
  synthetic remote listing, and the user's ask (list/pull/push/rm) doesn't
  require it. Would slot in as a `marked` set on entries plus tweaks to
  `do_pull`/`do_delete` to iterate it, if ever needed.
- **Auto-open after pull.** Enter only navigates directories; it does not
  pull-and-launch files. Kept the surface area to exactly what was asked
  for (list, pull, push, rm, root-retry) rather than inventing an "open"
  flow that wasn't requested.
- **Windows host support.** `adb.lua`'s local-path joining assumes POSIX
  (`/`) on the host running Yazi. Untested on Windows, same caveat
  `mount.yazi`'s own README carries.
- **A `refresh` sub-command / pubsub hook.** `M:entry()` checks
  `job.args[1]` and no-ops if set, as a placeholder for a future
  externally-triggered refresh (e.g. on device (dis)connect via a udev-style
  watcher), mirroring `mount.yazi`'s `ps.sub("mount", ...)` pattern. Not
  implemented because there's no equivalent low-cost device-connect event
  source for adb the way there is for block devices.

## Testing

`test.lua` stubs Yazi's `Command` global and `ya.sleep`, and exercises
`adb.lua`'s pure functions (`quote`, `join`, `parent`, `is_perm_denied`,
`devices`, `list`, `root`) end-to-end without a running Yazi instance or a
real device. Run with:

```sh
lua test.lua
```

`main.lua` is *not* covered by `test.lua` — it's almost entirely Yazi
runtime glue (`ya.sync`, `Modal`, `ui.*`) that only makes sense running
inside Yazi. Verifying it means installing the plugin (see README) and
exercising it against a real device or emulator. If you add non-trivial
logic to `main.lua` that doesn't depend on Yazi globals, consider moving it
into `adb.lua` (or a new pure module) so it's testable the same way.

The full flow (device auto-select, `ls` parsing/rendering, directory
navigation, the permission-denied → root-retry dialog in both accept and
decline directions, and `pull`) has been exercised live against a real
device, driven via `tmux send-keys`/`capture-pane` rather than by hand.
That's how the nested-prompt bug above was actually found — worth reaching
for again after any change to `main.lua`'s input handling, since that class
of bug is invisible from reading the code or from `test.lua`. Two notes
from doing it:
- Send keys one at a time with a short sleep between them
  (`for i in ...; do tmux send-keys ...; sleep 0.05; done`), not as one
  bulk string. A burst of `tmux send-keys -t s "jjjjjjjj"` visibly drops
  keystrokes against this plugin's `ya.which`-based input loop — unclear
  whether that's a tmux, terminal, or Yazi-side buffering limit, but it's
  a testing artifact, not a real user-facing issue (nobody hand-types a
  burst of 40 keys in one frame).
- Don't pull `/data_mirror` (or anything under it) as a smoke test — it's
  Android's full bind-mount mirror of `/data` and the recursive `adb pull`
  can run for a very long time. `init.environ.rc` at the device root is a
  small, safe, always-present file for a quick pull check.

## Layout

- `main.lua` — the plugin entry point, state machine, and UI. Everything
  Yazi-specific lives here.
- `adb.lua` — pure wrapper around the `adb` CLI. No Yazi globals except
  `ya.sleep` (used for the root-retry poll) and the ambient `Command`
  global. Kept separate specifically so it's unit-testable (see above).
- `test.lua` — offline tests for `adb.lua`.
- `README.md` — user-facing install/usage.
