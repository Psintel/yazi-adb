-- Thin wrapper around the `adb` CLI. No Yazi-specific state lives here --
-- everything in this module is a pure function of its arguments, so it can
-- be exercised without a running Yazi instance (see ARCHITECTURE.md).

local M = {}

-- POSIX shell single-quote escaping, for building the one-string command we
-- send after `adb shell`. See ARCHITECTURE.md "Why we hand-build shell strings".
function M.quote(s)
	return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

function M.join(dir, name)
	if dir == "/" then
		return "/" .. name
	end
	return dir .. "/" .. name
end

-- Parent of a device-side POSIX path, or nil if `path` is already "/".
function M.parent(path)
	if path == "/" or path == "" or path == nil then
		return nil
	end
	local trimmed = path:match("^(.*)/[^/]+$")
	if trimmed == nil or trimmed == "" then
		return "/"
	end
	return trimmed
end

local function run(args) return Command("adb"):arg(args):output() end

local function run_shell(device, cmd) return run({ "-s", device, "shell", cmd }) end

function M.is_perm_denied(text)
	if not text then
		return false
	end
	return text:find("Permission denied", 1, true) ~= nil
end

-- Returns a list of { id, state, model } for `adb devices -l`.
-- `state` is adb's own vocabulary: "device", "unauthorized", "offline", etc.
function M.devices()
	local output, err = run({ "devices", "-l" })
	if not output then
		return nil, tostring(err)
	end
	if not output.status.success then
		return nil, output.stderr ~= "" and output.stderr or "`adb devices` failed"
	end

	local list = {}
	for line in output.stdout:gmatch("[^\r\n]+") do
		if not line:find("^List of devices") and line:match("%S") then
			local id, state, rest = line:match("^(%S+)%s+(%S+)%s*(.*)$")
			if id then
				list[#list + 1] = { id = id, state = state, model = rest:match("model:(%S+)") }
			end
		end
	end
	return list
end

-- Parses one `ls -la` line into { name, is_dir, is_link, perm, size,
-- modified, link_to }, or nil for lines that aren't entries (e.g. "total 8").
--
-- Assumes the toybox `ls` shipped on modern Android (AOSP default since
-- Marshmallow). Older BusyBox/toolbox builds may format columns differently;
-- see ARCHITECTURE.md "ls parsing" for the known-fragile spots.
local function parse_entry(line)
	if line:match("^total%s") then
		return nil
	end

	local kind, perm, _links, _owner, group, size, date, time, name =
		line:match("^([%-dlbcps])([%-rwxsStT]+)%s+(%d+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%S+)%s+(%S+)%s+(.+)$")

	if not kind then
		-- Some ls builds omit the group column.
		kind, perm, _links, _owner, size, date, time, name =
			line:match("^([%-dlbcps])([%-rwxsStT]+)%s+(%d+)%s+(%S+)%s+(%d+)%s+(%S+)%s+(%S+)%s+(.+)$")
		group = nil
	end

	if not kind then
		return nil
	end

	local link_to
	if kind == "l" then
		local n, t = name:match("^(.-) %-> (.+)$")
		if n then
			name, link_to = n, t
		end
	end

	return {
		name = name,
		is_dir = kind == "d",
		is_link = kind == "l",
		perm = kind .. perm,
		size = tonumber(size) or 0,
		modified = date .. " " .. time,
		link_to = link_to,
	}
end

-- Lists `path` on `device`. Returns (entries, nil) or (nil, err_string).
-- `err_string` is the raw stderr text so callers can pattern-match it (e.g.
-- `is_perm_denied`) to decide whether to offer a root retry.
function M.list(device, path)
	local output, err = run_shell(device, "ls -la -- " .. M.quote(path))
	if not output then
		return nil, tostring(err)
	end
	if not output.status.success then
		return nil, output.stderr ~= "" and output.stderr or ("Failed to list " .. path)
	end

	local entries = {}
	for line in output.stdout:gmatch("[^\r\n]+") do
		local e = parse_entry(line)
		if e and e.name ~= "." and e.name ~= ".." then
			entries[#entries + 1] = e
		end
	end

	table.sort(entries, function(a, b)
		if a.is_dir ~= b.is_dir then
			return a.is_dir
		end
		return a.name:lower() < b.name:lower()
	end)

	return entries
end

-- `adb pull` handles recursive directory copies natively, so this works for
-- both files and directories.
function M.pull(device, remote, local_path)
	local output, err = run({ "-s", device, "pull", remote, local_path })
	if not output then
		return false, tostring(err)
	end
	if not output.status.success then
		return false, output.stderr ~= "" and output.stderr or "adb pull failed"
	end
	return true
end

-- `adb push` also handles directories natively.
function M.push(device, local_path, remote)
	local output, err = run({ "-s", device, "push", local_path, remote })
	if not output then
		return false, tostring(err)
	end
	if not output.status.success then
		return false, output.stderr ~= "" and output.stderr or "adb push failed"
	end
	return true
end

function M.rm(device, path)
	local output, err = run_shell(device, "rm -rf -- " .. M.quote(path))
	if not output then
		return false, tostring(err)
	end
	if not output.status.success then
		return false, output.stderr ~= "" and output.stderr or "rm failed"
	end
	return true
end

-- Requests `adbd` restart as root, then polls `get-state` (never
-- `wait-for-device`, which blocks with no timeout) until the daemon is back
-- or we give up after ~10s. Returns (true, nil) or (false, err_string).
function M.root(device)
	local output, err = run({ "-s", device, "root" })
	if not output then
		return false, tostring(err)
	end

	local text = output.stdout .. output.stderr
	if text:find("cannot run as root in production builds", 1, true) then
		return false, "Device build does not allow root (production build)"
	end
	if text:find("already running as root", 1, true) then
		return true
	end

	for _ = 1, 20 do
		ya.sleep(0.5)
		local state = run({ "-s", device, "get-state" })
		if state and state.status.success and state.stdout:find("device", 1, true) then
			return true
		end
	end
	return false, "Device did not come back online after requesting root"
end

return M
