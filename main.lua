--- @since 26.5.6

-- ADB explorer for Yazi. See ARCHITECTURE.md before touching the sync/async
-- split below -- it looks like boilerplate but every getter/setter pair
-- exists because entry()/producer/consumer run in an isolated async Lua
-- context that does NOT share self with the sync context redraw() runs
-- in. Reading state directly in async code silently sees stale/empty data.

local adb = require(".adb")

local M = {
default_path = "/",
status = "",
mode = "devices", -- "devices" | "browser"
devices = {},
entries = {},
dev_cursor = 0,
cursor = 0,

-- Static; identical in every context, so async code may read `self.keys`
-- directly (mirrors yazi-rs/plugins mount.yazi).
keys = {
		{ on = "q", run = "quit" },
		{ on = "<Esc>", run = "quit" },
		{ on = "<Enter>", run = "enter" },
		{ on = "l", run = "enter" },
		{ on = "<Right>", run = "enter" },
		{ on = "h", run = "back" },
		{ on = "<Left>", run = "back" },
		{ on = "<Backspace>", run = "back" },
		{ on = "k", run = "up" },
		{ on = "<Up>", run = "up" },
		{ on = "j", run = "down" },
		{ on = "<Down>", run = "down" },
		{ on = "R", run = "refresh" },
		{ on = "p", run = "pull" },
		{ on = "P", run = "push" },
		{ on = "d", run = "delete" },
		{ on = "r", run = "root" },
	},
}

function M:setup(opts)
	opts = opts or {}
	self.default_path = opts.default_path or "/"
end

-- Sync-context mutators. Each one both mutates state and calls
-- ui.render(), matching the pattern used throughout Yazi's own preset
-- components and third-party plugins (see mount.yazi).

local toggle_ui = ya.sync(function(self)
	if self.children then
		Modal:children_remove(self.children)
		self.children = nil
	else
		self.children = Modal:children_add(self, 10)
	end
ui.render()
end)

local set_status = ya.sync(function(self, text)
	self.status = text or ""
	ui.render()
end)

local set_devices = ya.sync(function(self, devices)
	self.devices = devices or {}
	self.dev_cursor = math.max(0, math.min(self.dev_cursor or 0, #self.devices - 1))
	ui.render()
end)

local set_entries = ya.sync(function(self, entries)
	self.entries = entries or {}
	self.cursor = math.max(0, math.min(self.cursor or 0, #self.entries - 1))
	ui.render()
end)

local move_cursor = ya.sync(function(self, delta)
local list = self.mode == "devices" and self.devices or self.entries
local field = self.mode == "devices" and "dev_cursor" or "cursor"
local cur = self[field] or 0
self[field] = #list == 0 and 0 or ya.clamp(0, cur + delta, #list - 1)
ui.render()
end)

local enter_browser = ya.sync(function(self, device, path)
self.device = device
self.path = path
self.mode = "browser"
self.cursor = 0
self.entries = {}
ui.render()
end)

local enter_devices = ya.sync(function(self)
self.mode = "devices"
ui.render()
end)

-- Sync-context getters. Needed for anything async code must read that
-- isn't the static keys table -- see the module-level comment above.

local get_mode = ya.sync(function(self) return self.mode end)
local get_device = ya.sync(function(self) return self.device end)
local get_path = ya.sync(function(self) return self.path end)
local get_default_path = ya.sync(function(self) return self.default_path end)
local device_count = ya.sync(function(self) return #self.devices end)
local active_device = ya.sync(function(self) return self.devices[(self.dev_cursor or 0) + 1] end)
local active_entry = ya.sync(function(self) return self.entries[(self.cursor or 0) + 1] end)

-- The real (non-adb) Yazi pane that pull/push read/write against.
local real_cwd = ya.sync(function() return cx.active.current.cwd end)
local real_hovered = ya.sync(function() return cx.active.current.hovered end)

local function notify(content, level)
ya.notify { title = "ADB", content = content, level = level or "info", timeout = level == "error" and 6 or 4 }
end

local real_selected = ya.sync(function()
local items = {}

for _, file in pairs(cx.active.selected) do
    local path = tostring(file.url)

    items[#items + 1] = {
        path = path,
        name = file.name,
    }
end

return items

end)

-- Async entry point. Everything below runs in the async context.

function M:entry(job)
if job.args[1] then
return -- no sub-commands yet; reserved for a future pubsub refresh hook
end

-- `producer()` below sits in a tight loop on `ya.which{silent=true}`,
-- which is *the* input sink while it's outstanding -- a concurrently
-- issued `ya.confirm`/`ya.input` never receives a keystroke while it's
-- pending (confirmed live: the dialog rendered but every key was a
-- no-op). `mount.yazi` hits the same issue for its sudo-password prompt
-- and fixes it with exactly this permit handshake: hand the (single-
-- buffered) permit channel a token, force-cancel the outstanding
-- `ya.which` with `which:dismiss`, and producer's own post-which send
-- blocks on the full channel until we drain it here, i.e. producer is
-- parked for the duration of `fn`. See ARCHITECTURE.md "Nested prompts".
local permit_tx, permit_rx = ya.chan("mpsc", 1)

local function with_input_paused(fn)
	permit_tx:send(true)
	ya.emit("which:dismiss", {})
	local ok, a, b = pcall(fn)
	permit_rx:recv()
	if not ok then
		error(a, 0)
	end
	return a, b
end

-- Requirement 6: on a permission error, ask whether to `adb -s <id> root`
-- and retry once. Returns true if the caller should retry its operation.
local function maybe_offer_root(device, err)
	if not adb.is_perm_denied(err or "") then
		return false
	end

	local answer = with_input_paused(function()
		return ya.confirm {
			pos = { "center", w = 60, h = 10 },
			title = "Permission denied",
			body = string.format("Retry as root on %s?\n\nThis runs `adb -s %s root`.", device, device),
		}
	end)
	if not answer then
		return false
	end

	set_status("Requesting root...")
	local ok, rerr = adb.root(device)
	set_status("")
	if not ok then
		notify("Root request failed: " .. tostring(rerr), "error")
		return false
	end

	notify("Now running as root on " .. device)
	return true
end

local function reload_devices()
	set_status("Loading devices...")
	local devices, err = adb.devices()
	set_status("")
	if not devices then
		notify("Failed to list devices: " .. tostring(err), "error")
		return {}
	end
	return devices
end

local function reload_list()
	local device, path = get_device(), get_path()
	if not device or not path then
		return
	end

	set_status("Loading...")
	local entries, err = adb.list(device, path)
	if not entries and maybe_offer_root(device, err) then
		entries, err = adb.list(device, path)
	end
	set_status("")

	if not entries then
		notify(string.format("Failed to list %s: %s", path, tostring(err)), "error")
		set_entries({})
	else
		set_entries(entries)
	end
end

local function do_pull()
	local e = active_entry()
	if not e then
		return notify("No file selected", "warn")
	end

	local device, path = get_device(), get_path()
	local remote = adb.join(path, e.name)
	local dest = tostring(real_cwd()) .. "/" .. e.name

	set_status("Pulling " .. e.name .. "...")
	local ok, err = adb.pull(device, remote, dest)
	if not ok and maybe_offer_root(device, err) then
		ok, err = adb.pull(device, remote, dest)
	end
	set_status("")

	if ok then
		notify("Pulled " .. e.name .. " to " .. dest)
		ya.emit("refresh", {})
	else
		notify("Pull failed: " .. tostring(err), "error")
	end
end

local function do_push()
	local ok, items = pcall(real_selected)
	if not ok then
		return notify("real_selected error: " .. tostring(items), "error")
	end
	items = items or {}

	local source = #items > 0 and "selection" or "hovered"
	if #items == 0 then
		local hovered = real_hovered()
		if not hovered then
			return notify("Nothing to push: нет выделения и нет файла под курсором", "warn")
		end
		local p = tostring(hovered.url)
		items[1] = { path = p, name = hovered.name or p:match("[^/]+$") }
	end

	local device, path = get_device(), get_path()
	notify(string.format("Pushing %d item(s) [%s] → %s", #items, source, tostring(path)))

	local pushed, failed = 0, 0
	for i, it in ipairs(items) do
		set_status(string.format("Pushing %d/%d: %s", i, #items, it.name))
		local ok2, err = adb.push(device, it.path, path)
		if not ok2 and maybe_offer_root(device, err) then
			ok2, err = adb.push(device, it.path, path)
		end
		if ok2 then
			pushed = pushed + 1
		else
			failed = failed + 1
			notify("Push failed: " .. it.name .. ": " .. tostring(err), "error")
		end
	end
	set_status("")

	if pushed > 0 then
		notify(string.format("Pushed %d item(s)%s", pushed, failed > 0 and (", " .. failed .. " failed") or ""))
		reload_list()
	end
end

local function do_delete()
	local e = active_entry()
	if not e then
		return
	end

	local device, path = get_device(), get_path()
	local target = adb.join(path, e.name)

	local answer = with_input_paused(function()
		return ya.confirm {
			pos = { "center", w = 60, h = 10 },
			title = "Delete",
			body = string.format("Delete %s from %s%s?", e.name, device, target),
		}
	end)
	if not answer then
		return
	end

	set_status("Deleting " .. e.name .. "...")
	local ok, err = adb.rm(device, target)
	if not ok and maybe_offer_root(device, err) then
		ok, err = adb.rm(device, target)
	end
	set_status("")

	if ok then
		notify("Deleted " .. e.name)
		reload_list()
	else
		notify("Delete failed: " .. tostring(err), "error")
	end
end

toggle_ui()

-- Requirement 1: only show the device picker when there's more than one.
local devices = reload_devices()
if #devices == 0 then
	toggle_ui()
	return
end

set_devices(devices)
if #devices == 1 then
	enter_browser(devices[1].id, get_default_path())
	reload_list()
else
	enter_devices()
end

local tx, rx = ya.chan("mpsc")

local function producer()
	permit_tx:send(true)
	while true do
		permit_rx:recv()
		local idx = ya.which { cands = self.keys, silent = true }
		permit_tx:send(true)

		local cand = self.keys[idx]
		if cand and cand.run then
			tx:send(cand.run)
			if cand.run == "quit" then
				return
			end
		end
	end
end

local function consumer()
	repeat
		local run = rx:recv()

		if run == "quit" then
			break
		elseif run == "up" then
			move_cursor(-1)
		elseif run == "down" then
			move_cursor(1)
		elseif run == "enter" then
			if get_mode() == "devices" then
				local d = active_device()
				if d then
					enter_browser(d.id, get_default_path())
					reload_list()
				end
			else
				local e = active_entry()
				if e and e.is_dir then
					enter_browser(get_device(), adb.join(get_path(), e.name))
					reload_list()
				end
			end
		elseif run == "back" then
			if get_mode() == "browser" then
				local parent = adb.parent(get_path())
				if parent then
					enter_browser(get_device(), parent)
					reload_list()
				elseif device_count() > 1 then
					enter_devices()
				end
			end
		elseif run == "refresh" then
			if get_mode() == "devices" then
				set_devices(reload_devices())
			else
				reload_list()
			end
		elseif run == "pull" then
			if get_mode() == "browser" then
				do_pull()
			end
		elseif run == "push" then
			if get_mode() == "browser" then
				do_push()
			end
		elseif run == "delete" then
			if get_mode() == "browser" then
				do_delete()
			end
		elseif run == "root" then
			if get_mode() == "browser" then
				if maybe_offer_root(get_device(), "Permission denied") then
					reload_list()
				end
			end
		end
	until not run
end

ya.join(producer, consumer)
toggle_ui()

end

-- Sync-context rendering. self here is the canonical, persistent
-- instance -- all fields below reflect the latest sync setter calls above.

function M:new(area)
self:layout(area)
return self
end

function M:layout(area)
local v = ui.Layout()
:constraints({ ui.Constraint.Percentage(10), ui.Constraint.Percentage(80), ui.Constraint.Percentage(10) })
:split(area)


local h = ui.Layout()
	:direction(ui.Layout.HORIZONTAL)
	:constraints({ ui.Constraint.Percentage(10), ui.Constraint.Percentage(80), ui.Constraint.Percentage(10) })
	:split(v[2])

self._area = h[2]

end

function M:reflow() return { self } end

function M:redraw()
	if self.mode == "devices" then
		return self:redraw_devices()
	end
	return self:redraw_browser()
end

function M:redraw_devices()
local area = self._area:pad(ui.Pad(1, 2, 1, 2))
local devices = self.devices or {}
local cursor = self.dev_cursor or 0
local title = "ADB Devices"
if self.status ~= "" then
    title = title .. "  " .. self.status
end

local lines = {
    ui.Line("Connected Android devices:"),
    ui.Line(""),
}

for i, d in ipairs(devices) do
    local text = string.format(
        "%s  %s  [%s]",
        d.id,
        d.model or "Unknown",
        d.state or "unknown"
    )

    local line = ui.Line(text)

    if i - 1 == cursor then
        line = line:style(ui.Style():reverse())
    end

    lines[#lines + 1] = line
end

return {
    ui.Clear(self._area),

ui.Border(ui.Edge.ALL)
    :area(self._area)
    :set { as = ui.Border.ROUNDED }
    :style(ui.Style():fg("blue"))
    :title(ui.Line(title):align(ui.Align.CENTER)),

    ui.Text(lines)
        :area(area),
}

end

function M:redraw_browser()
local area = self._area:pad(ui.Pad(1, 2, 1, 2))
local entries = self.entries or {}
local cursor = self.cursor or 0


local lines = {}
local height = area.h

-- Прокрутка списка
local offset = math.max(0, cursor - height + 1)

for i = offset + 1, math.min(#entries, offset + height) do
    local e = entries[i]

    local name = e.name
    if e.is_dir then
        name = name .. "/"
    elseif e.is_link then
        name = name .. " -> " .. (e.link_to or "?")
    end

    local prefix = (i - 1 == cursor) and "> " or "  "

    local line = ui.Line {
        ui.Span(prefix),
        ui.Span(name):style(
            ui.Style():fg(e.is_dir and "blue" or "white")
        ),
    }

    if i - 1 == cursor then
        line = line:style(ui.Style():reverse())
    end

    lines[#lines + 1] = line
end

local title = string.format(
    "adb://%s%s",
    self.device or "",
    self.path or "/"
)

if self.status ~= "" then
    title = title .. "  " .. self.status
end

return {
    ui.Clear(self._area),

    ui.Border(ui.Edge.ALL)
        :area(self._area)
        :style(ui.Style():fg("blue")),

    ui.Text(lines)
        :area(area),
}

end

function M:click() end

function M:scroll() end

function M:touch() end

return M
