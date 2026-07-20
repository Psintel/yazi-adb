-- Offline unit tests for adb.lua's pure logic, run with plain `lua test.lua`
-- (no Yazi runtime required). Stubs just enough of Yazi's globals (Command,
-- ya.sleep) to exercise adb.lua end-to-end. See ARCHITECTURE.md "Testing".

local failures = 0

local function assert_eq(got, want, msg)
	if got ~= want then
		failures = failures + 1
		print(string.format("FAIL %s: got %s, want %s", msg, tostring(got), tostring(want)))
	end
end

-- --- Stub `Command` -----------------------------------------------------
-- Each test installs `_G.next_outputs`, a queue of canned
-- { stdout, stderr, success } results consumed in call order, and records
-- every invocation in `_G.calls` for assertions on what was actually run.

_G.calls = {}
_G.next_outputs = {}

local CommandMt = {}
CommandMt.__index = CommandMt

function CommandMt:arg(a)
	if type(a) == "table" then
		for _, v in ipairs(a) do
			table.insert(self._args, v)
		end
	else
		table.insert(self._args, a)
	end
	return self
end

function CommandMt:output()
	table.insert(_G.calls, table.concat(self._args, " "))
	local out = table.remove(_G.next_outputs, 1)
	if not out then
		error("test.lua: no stubbed output queued for: " .. table.concat(self._args, " "))
	end
	return { stdout = out.stdout or "", stderr = out.stderr or "", status = { success = out.success ~= false } }
end

_G.Command = setmetatable({}, {
	__call = function(_, program)
		return setmetatable({ _args = { program } }, CommandMt)
	end,
})

_G.ya = { sleep = function() end }

local function reset(outputs)
	_G.calls = {}
	_G.next_outputs = outputs
end

package.path = (arg[0]:match("(.*/)") or "./") .. "?.lua;" .. package.path
local adb = require("adb")

-- --- quote / join / parent ----------------------------------------------

assert_eq(adb.quote("/sdcard/a b"), "'/sdcard/a b'", "quote: plain space")
assert_eq(adb.quote("it's"), [['it'\''s']], "quote: embedded apostrophe")

assert_eq(adb.join("/", "sdcard"), "/sdcard", "join: from root")
assert_eq(adb.join("/sdcard", "DCIM"), "/sdcard/DCIM", "join: nested")

assert_eq(adb.parent("/"), nil, "parent: root has no parent")
assert_eq(adb.parent("/sdcard"), "/", "parent: one level deep")
assert_eq(adb.parent("/sdcard/DCIM"), "/sdcard", "parent: two levels deep")

-- --- is_perm_denied -------------------------------------------------------

assert_eq(adb.is_perm_denied("ls: /data: Permission denied"), true, "perm_denied: match")
assert_eq(adb.is_perm_denied("No such file or directory"), false, "perm_denied: no match")
assert_eq(adb.is_perm_denied(nil), false, "perm_denied: nil")

-- --- devices() -------------------------------------------------------------

reset {
	{
		stdout = table.concat({
			"List of devices attached",
			"emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1",
			"0123456789ABCDEF       unauthorized transport_id:2",
			"",
		}, "\n"),
	},
}
local devices = adb.devices()
assert_eq(#devices, 2, "devices: count")
assert_eq(devices[1].id, "emulator-5554", "devices: first id")
assert_eq(devices[1].state, "device", "devices: first state")
assert_eq(devices[1].model, "sdk_gphone64_arm64", "devices: first model")
assert_eq(devices[2].id, "0123456789ABCDEF", "devices: second id")
assert_eq(devices[2].state, "unauthorized", "devices: second state")
assert_eq(devices[2].model, nil, "devices: second model absent")

-- --- list() (ls -la parsing) ------------------------------------------------

reset {
	{
		stdout = table.concat({
			"total 16",
			"drwxrwx--x 6 root sdcard_rw 4096 2024-01-02 03:04 Android",
			"-rw-rw---- 1 root sdcard_rw 1024 2024-01-02 03:05 note.txt",
			"lrwxrwxrwx 1 root root 11 2024-01-02 03:06 link -> note.txt",
			"",
		}, "\n"),
	},
}
local entries = adb.list("emulator-5554", "/sdcard")
assert_eq(#_G.calls, 1, "list: one adb invocation")
assert_eq(#entries, 3, "list: entry count")
-- Sorted dirs-first, then alphabetically.
assert_eq(entries[1].name, "Android", "list: dir sorts first")
assert_eq(entries[1].is_dir, true, "list: Android is_dir")
assert_eq(entries[2].name, "link", "list: link name (arrow stripped)")
assert_eq(entries[2].is_link, true, "list: link is_link")
assert_eq(entries[2].link_to, "note.txt", "list: link target")
assert_eq(entries[3].name, "note.txt", "list: note.txt")
assert_eq(entries[3].size, 1024, "list: note.txt size")

reset { { stdout = "", stderr = "ls: /data: Permission denied", success = false } }
local nilres, err = adb.list("emulator-5554", "/data")
assert_eq(nilres, nil, "list: permission denied returns nil")
assert_eq(adb.is_perm_denied(err), true, "list: permission denied err text")

-- --- root() ------------------------------------------------------------

reset {
	{ stdout = "restarting adbd as root\n" },
	{ stdout = "device\n" },
}
local ok = adb.root("emulator-5554")
assert_eq(ok, true, "root: success after one get-state poll")
assert_eq(#_G.calls, 2, "root: root + one get-state call")

reset { { stdout = "adbd cannot run as root in production builds\n" } }
local ok2, err2 = adb.root("device-1")
assert_eq(ok2, false, "root: refused on production build")
assert_eq(err2, "Device build does not allow root (production build)", "root: production build message")

if failures == 0 then
	print("All tests passed.")
else
	print(failures .. " test(s) failed.")
	os.exit(1)
end
