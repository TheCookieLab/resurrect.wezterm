-- Storage behaviour: paths, directory creation, named saves, session generations.
-- Run inside WezTerm's embedded Lua by tests/test_resurrect.py; any failed
-- assertion aborts the config and therefore the test.
local wezterm = require("wezterm")

local root = assert(os.getenv("RESURRECT_TEST_DIR"), "RESURRECT_TEST_DIR is required")

-- Independent of the layout implementation: storage only needs these two calls.
package.loaded["resurrect.session_state"] = {
	validate = function(state)
		if type(state) ~= "table" or state.format_version ~= 1 then
			return nil, "unsupported format"
		end
		if type(state.windows) ~= "table" then
			return nil, "windows missing"
		end
		return true
	end,
	counts = function(state)
		return { windows = #state.windows, tabs = state.tabs or 0, panes = state.panes or 0 }
	end,
}

local utils = require("resurrect.utils")
local file_io = require("resurrect.file_io")
local state_manager = require("resurrect.state_manager")
local fuzzy_loader = require("resurrect.fuzzy_loader")

local errors = {}
wezterm.on("resurrect.error", function(message)
	table.insert(errors, message)
end)

local function eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function truthy(value, label)
	if not value then
		error((label or "expected a truthy value") .. " (got " .. tostring(value) .. ")", 2)
	end
	return value
end

local function names(dir)
	local ok, entries = pcall(wezterm.read_dir, dir)
	if not ok then
		return nil
	end
	local result = {}
	for _, entry in ipairs(entries) do
		table.insert(result, (entry:match("[^/\\]+$")))
	end
	table.sort(result)
	return result
end

local function has_name(list, wanted)
	for _, name in ipairs(list or {}) do
		if name == wanted then
			return true
		end
	end
	return false
end

local function count_matching(list, pattern)
	local n = 0
	for _, name in ipairs(list or {}) do
		if name:find(pattern) then
			n = n + 1
		end
	end
	return n
end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(text))
	assert(handle:close())
end

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("a")
	handle:close()
	return text
end

-- Paths -------------------------------------------------------------------

do
	local was_windows = utils.is_windows

	utils.is_windows = true
	eq(utils.join_path("C:/a/", "b", "/c/"), "C:\\a\\b\\c", "windows join")
	eq(utils.join_path("C:\\", "x"), "C:\\x", "drive root")
	eq(utils.join_path("C:", "x"), "C:\\x", "bare drive")
	eq(utils.join_path("C:/Users/Jörg Ünï/My Dir", "é ü"), "C:\\Users\\Jörg Ünï\\My Dir\\é ü", "spaces and unicode")
	eq(utils.join_path("\\\\server\\share\\", "dir", "f"), "\\\\server\\share\\dir\\f", "unc share")
	eq(utils.join_path("\\\\server\\share", "dir"), "\\\\server\\share\\dir", "unc without trailing")
	eq(utils.is_absolute_path("C:\\x"), true, "drive absolute")
	eq(utils.is_absolute_path("C:/x"), true, "drive slash absolute")
	eq(utils.is_absolute_path("\\\\srv\\share"), true, "unc absolute")
	eq(utils.is_absolute_path("C:x"), false, "drive relative")
	eq(utils.is_absolute_path("\\x"), false, "current drive root")
	eq(utils.is_absolute_path("rel\\x"), false, "relative")
	eq(utils.dirname("C:\\a\\b.json"), "C:\\a", "windows dirname")
	eq(utils.basename("C:\\a\\b.json"), "b.json", "windows basename")

	utils.is_windows = false
	eq(utils.join_path("/a/", "b"), "/a/b", "posix join")
	eq(utils.join_path("/a", "/b/", "c"), "/a/b/c", "posix join leading separators")
	eq(utils.join_path("/", "x"), "/x", "posix root")
	eq(utils.join_path("/a b", "é ü"), "/a b/é ü", "posix spaces and unicode")
	eq(utils.join_path("/mnt/c/Users", "x"), "/mnt/c/Users/x", "WSL path stays a WSL path")
	eq(utils.is_absolute_path("/x"), true, "posix absolute")
	eq(utils.is_absolute_path("x/y"), false, "posix relative")
	eq(utils.dirname("/a/b.json"), "/a", "posix dirname")
	eq(utils.dirname("/b.json"), "/", "posix root dirname")

	utils.is_windows = was_windows
end

do
	local sample = { "a/b", "a+b", "A", "a", "CON", "con", "x.", "x ", "x", "", "..", "é", "a\\b", "a:b" }
	local seen = {}
	for _, name in ipairs(sample) do
		local stem = utils.encode_state_name(name)
		eq(seen[stem], nil, "stem collision for " .. name)
		seen[stem] = name
		eq(utils.decode_state_name(stem), name, "decode " .. name)
		truthy(stem:match("^s%-[0-9a-f]*$"), "stem is plain hex")
	end
	eq(utils.decode_state_name("foo+bar"), nil, "foreign stem")
	eq(utils.decode_state_name("s-abc"), nil, "odd hex")
	eq(utils.decode_state_name("s-ZZ"), nil, "non hex")
end

-- ensure_folder_exists ------------------------------------------------------

do
	local nested = utils.join_path(root, "made", "very deep", "ünï")
	local ok, err = utils.ensure_folder_exists(nested)
	truthy(ok, "create nested folders: " .. tostring(err))
	truthy(names(nested), "folder exists")
	truthy(utils.ensure_folder_exists(nested), "idempotent")
	truthy(utils.ensure_folder_exists(utils.join_path(nested) .. "/"), "trailing separator")

	local file = utils.join_path(root, "plain-file")
	write(file, "x")
	local blocked, blocked_err = utils.ensure_folder_exists(utils.join_path(file, "child"))
	eq(blocked, nil, "file as directory component fails")
	truthy(blocked_err and blocked_err ~= "", "file as directory reports an error")
	eq(read(file), "x", "blocking file untouched")

	if utils.is_windows then
		eq((utils.ensure_folder_exists("C:relative")), nil, "drive relative rejected")
		local invalid = utils.ensure_folder_exists(utils.join_path(root, "bad<name"))
		eq(invalid, nil, "invalid characters fail")
	else
		local bad = utils.ensure_folder_exists("")
		eq(bad, nil, "empty path rejected")
	end
	eq((utils.ensure_folder_exists("a\nb")), nil, "control characters rejected")
end

-- Named saves -----------------------------------------------------------------

local state_root = utils.join_path(root, "state")

do
	local dir_ok, dir_err = state_manager.change_state_save_dir(utils.join_path(root, "nowhere", "yet"))
	eq(dir_ok, true, "change_state_save_dir")
	eq(dir_err, nil, "change_state_save_dir error")
	eq(names(utils.join_path(root, "nowhere")), nil, "change_state_save_dir performs no I/O")
	eq((state_manager.change_state_save_dir(nil)), nil, "nil directory rejected")
	eq((state_manager.change_state_save_dir("")), nil, "empty directory rejected")
end

-- Nothing is configured: saving fails visibly instead of writing somewhere.
state_manager.save_state_dir = nil
do
	local path, err = state_manager.save_state({ workspace = "w", window_states = {} })
	eq(path, nil, "unconfigured save")
	truthy(err and err:find("change_state_save_dir", 1, true), "unconfigured message")
end

eq(state_manager.change_state_save_dir(state_root .. "/"), true, "set root with trailing separator")

do
	local type_name = state_manager.parse_state_id("workspace/" .. utils.encode_state_name("a/b é") .. ".json")
	eq(type_name, "workspace", "parse type")
	local _, name = state_manager.parse_state_id("workspace/" .. utils.encode_state_name("a/b é") .. ".json")
	eq(name, "a/b é", "parse name")
	eq((state_manager.parse_state_id("workspace/foo+bar.json")), nil, "legacy filename is not an ID")
	eq((state_manager.parse_state_id("secrets/s-61.json")), nil, "unknown type")
	eq((state_manager.parse_state_id("workspace/../s-61.json")), nil, "traversal")
	eq((state_manager.parse_state_id("../workspace/s-61.json")), nil, "leading traversal")
end

do
	local workspace = { workspace = "main", window_states = {} }
	local path, err = state_manager.save_state(workspace)
	truthy(path, "save workspace: " .. tostring(err))
	eq(path, utils.join_path(state_root, "workspace", utils.encode_state_name("main") .. ".json"), "workspace path")
	eq(workspace.saved_at, nil, "caller's table is not modified")

	local loaded, warning = state_manager.load_state("main", "workspace")
	truthy(loaded, "load workspace")
	eq(warning, nil, "no warning for a clean load")
	eq(loaded.workspace, "main", "workspace name round trip")
	eq(math.type(loaded.saved_at), "integer", "saved_at stored")

	-- Distinct names never share a file.
	for _, title in ipairs({ "a/b", "a+b", "A", "a", "CON", "x.", "x ", "é ü" }) do
		local tab_path = truthy(state_manager.save_state({ title = title, pane_tree = {}, marker = title }))
		eq(state_manager.load_state(title, "tab").marker, title, "tab round trip " .. title)
		truthy(file_io.path_exists(tab_path), "tab file " .. title)
	end
	eq(count_matching(names(utils.join_path(state_root, "tab")), "%.json$"), 8, "eight distinct tab files")

	-- opt_name overrides the state's own name.
	truthy(state_manager.save_state({ title = "ignored", tabs = {} }, "chosen"))
	eq(state_manager.load_state("chosen", "window").title, "ignored", "opt_name")

	-- A second save keeps the previous good version as .bak.
	truthy(state_manager.save_state({ workspace = "main", window_states = {}, revision = 2 }))
	local workspace_dir = utils.join_path(state_root, "workspace")
	local stem = utils.encode_state_name("main") .. ".json"
	truthy(has_name(names(workspace_dir), stem .. ".bak"), "backup created")
	eq(state_manager.load_state("main", "workspace").revision, 2, "newest version loads")

	-- A damaged destination falls back to the backup and says so.
	write(path, '{"workspace":"main","window_sta')
	local before = #errors
	local fallback, fallback_warning = state_manager.load_state("main", "workspace")
	truthy(fallback, "backup used")
	eq(fallback.revision, nil, "backup is the previous version")
	truthy(fallback_warning and fallback_warning:find("previous", 1, true), "fallback warning")
	truthy(#errors > before, "fallback reported through resurrect.error")

	-- Saving over the damaged destination keeps its bytes and the valid backup.
	truthy(state_manager.save_state({ workspace = "main", window_states = {}, revision = 3 }))
	local after = names(workspace_dir)
	eq(count_matching(after, "%.corrupt%.%d+$"), 1, "damaged file preserved")
	truthy(has_name(after, stem .. ".bak"), "valid backup retained")
	eq(state_manager.load_state("main", "workspace").revision, 3, "replacement published")

	-- No file at all is a reported failure, not an empty state.
	local missing, missing_err = state_manager.load_state("never", "workspace")
	eq(missing, nil, "missing state")
	truthy(missing_err and missing_err ~= "", "missing state message")
	eq((state_manager.load_state("main", "../x")), nil, "unsupported type")

	-- Deleting is by listed ID only and removes the backup too.
	eq((state_manager.delete_state("workspace/../../outside.json")), nil, "traversal delete rejected")
	eq((state_manager.delete_state("workspace/plain.json")), nil, "unencoded delete rejected")
	truthy(state_manager.delete_state("workspace/" .. stem), "delete state")
	local remaining = names(workspace_dir)
	eq(has_name(remaining, stem), false, "state removed")
	eq(has_name(remaining, stem .. ".bak"), false, "backup removed")
	eq(count_matching(remaining, "%.corrupt%.%d+$"), 1, "evidence kept")
end

-- Marker publication ----------------------------------------------------------

do
	local marker = utils.join_path(root, "markers", "skip-once.json")
	truthy(file_io.publish_json(marker, { skip_restore = true }), "publish marker")
	eq(file_io.load_plain_json(marker).skip_restore, true, "marker content")
	eq(count_matching(names(utils.join_path(root, "markers")), "%.tmp$"), 0, "no leftover temp")

	write(marker, '{"skip_restore":true,"other":1}')
	truthy(file_io.publish_json(marker, { skip_restore = true }), "idempotent publish")
	eq(read(marker), '{"skip_restore":true,"other":1}', "valid marker untouched")

	write(marker, "{broken")
	truthy(file_io.publish_json(marker, { skip_restore = true }), "replace malformed marker")
	eq(file_io.load_plain_json(marker).skip_restore, true, "replacement valid")
	local list = names(utils.join_path(root, "markers"))
	eq(count_matching(list, "%.corrupt%.%d+$"), 1, "malformed marker preserved")
	local preserved
	for _, name in ipairs(list) do
		if name:find("%.corrupt%.") then
			preserved = read(utils.join_path(root, "markers", name))
		end
	end
	eq(preserved, "{broken", "malformed bytes kept")

	local picky = function(state)
		if state.skip_restore == true then
			return true
		end
		return nil, "not a skip marker"
	end
	write(marker, '{"skip_restore":false}')
	truthy(file_io.publish_json(marker, { skip_restore = true }, picky), "validator rejects existing")
	eq(file_io.load_plain_json(marker).skip_restore, true, "rejected marker replaced")
end

-- Full-session generations -------------------------------------------------

local function session(n, extra)
	local state = { format_version = 1, active_workspace = "main", windows = {} }
	for i = 1, n or 1 do
		state.windows[i] = { workspace = "main" }
	end
	for key, value in pairs(extra or {}) do
		state[key] = value
	end
	return state
end

local session_root = utils.join_path(root, "sessions")
eq(state_manager.change_state_save_dir(session_root), true, "session root")
local session_dir = utils.join_path(session_root, "session")

local function snapshot(n)
	return utils.join_path(session_dir, string.format("snapshot-%020d.json", n))
end

do
	-- Fresh start is a sentinel, not an error.
	local state, message, info = state_manager.load_session()
	eq(state, nil, "no session yet")
	eq(message, nil, "no session message")
	eq(info.kind, "missing", "missing sentinel")
	local records, warning = state_manager.list_sessions()
	eq(#records, 0, "no records")
	eq(warning, nil, "no listing warning")

	-- Invalid states are refused without leaving files.
	local rejected, rejected_err = state_manager.save_session({ format_version = 2, windows = {} })
	eq(rejected, nil, "unknown format refused")
	truthy(rejected_err, "refusal reason")
	eq(names(session_dir), nil, "refusal creates nothing")

	for generation = 1, 5 do
		local path, err = state_manager.save_session(session(generation, { marker = generation }))
		truthy(path, "save generation " .. generation .. ": " .. tostring(err))
		eq(path, snapshot(generation), "generation path " .. generation)
		eq(count_matching(names(session_dir), "%.tmp$"), 0, "no temp left after publish")
	end
	local files = names(session_dir)
	eq(#files, 3, "only the newest three valid generations are kept")
	eq(has_name(files, "snapshot-00000000000000000003.json"), true, "oldest kept")
	eq(has_name(files, "snapshot-00000000000000000002.json"), false, "pruned")

	local newest, warn, info2 = state_manager.load_session()
	eq(newest.marker, 5, "newest loads")
	eq(newest.generation, 5, "generation stamped")
	eq(math.type(newest.saved_at), "integer", "saved_at stamped")
	eq(warn, nil, "no warning")
	eq(info2.path, snapshot(5), "info path")

	-- A truncated newest generation falls back to the next valid one.
	local good_text = read(snapshot(5))
	write(snapshot(5), good_text:sub(1, #good_text // 2))
	local fallback, fallback_warning, fallback_info = state_manager.load_session()
	eq(fallback.marker, 4, "fallback generation")
	truthy(fallback_warning and fallback_warning ~= "", "fallback warning")
	eq(fallback_info.kind, "fallback", "fallback kind")

	local records, listing_warning = state_manager.list_sessions()
	eq(#records, 2, "invalid candidate excluded")
	eq(records[1].generation, 4, "newest first")
	eq(records[2].generation, 3, "older second")
	eq(records[1].id, snapshot(4), "record id is the immutable path")
	eq(records[1].windows, 4, "window count")
	truthy(listing_warning and listing_warning:find("1", 1, true), "listing summarised once")

	-- Leftover temp files are ignored for loading and numbering.
	write(snapshot(5) .. ".1.1.tmp", good_text)
	write(utils.join_path(session_dir, "snapshot-00000000000000000099.json.1.1.tmp"), good_text)

	-- A failed publication keeps every previous generation.
	local before = names(session_dir)
	local real_rename = os.rename
	os.rename = function()
		return nil, "simulated failure"
	end
	local failed, failed_err = state_manager.save_session(session(1, { marker = "never" }))
	os.rename = real_rename
	eq(failed, nil, "failed publish")
	truthy(failed_err and failed_err:find("simulated failure", 1, true), "failure reported")
	local after = names(session_dir)
	eq(#after, #before, "failed publish leaves no temp file behind")

	-- Numbering continues after the highest numbered file, even a corrupt one.
	local path6 = truthy(state_manager.save_session(session(2, { marker = 6 })))
	eq(path6, snapshot(6), "generation after corrupt newest")
	local list = names(session_dir)
	eq(has_name(list, "snapshot-00000000000000000005.json"), true, "corrupt file kept")
	eq(has_name(list, "snapshot-00000000000000000003.json"), true, "third valid generation still retained")
	eq(state_manager.load_session().marker, 6, "newest valid")

	-- Exact loads.
	local exact = state_manager.load_session(snapshot(4))
	eq(exact.marker, 4, "exact generation")
	local bad_exact, bad_err, bad_info = state_manager.load_session(snapshot(5))
	eq(bad_exact, nil, "corrupt exact")
	truthy(bad_err, "corrupt exact message")
	eq(bad_info.kind, "corrupt", "corrupt exact kind")
	local gone, gone_err, gone_info = state_manager.load_session(snapshot(2))
	eq(gone, nil, "pruned exact")
	eq(gone_err, nil, "pruned exact message")
	eq(gone_info.kind, "missing", "pruned exact kind")
	local outside = state_manager.load_session(utils.join_path(root, "other", "snapshot-00000000000000000001.json"))
	eq(outside, nil, "path outside session directory refused")
	eq((state_manager.load_session(utils.join_path(session_dir, "../escape.json"))), nil, "arbitrary path refused")

	-- The picker keeps decoded states: the oldest displayed record still has
	-- its contents after the files rotate away.
	local shown = state_manager.list_sessions()
	local oldest = shown[#shown]
	for i = 7, 9 do
		truthy(state_manager.save_session(session(1, { marker = i })))
	end
	eq(file_io.path_exists(oldest.id), false, "oldest displayed file pruned")
	eq(oldest.generation, 3, "oldest displayed generation")
	eq(oldest.state.marker, 3, "decoded state retained")
	truthy(oldest.state.windows, "oldest displayed state still has its windows")

	-- Every valid generation gone: damaged files stay, loading reports it.
	for _, name in ipairs(names(session_dir)) do
		write(utils.join_path(session_dir, name), "not json")
	end
	local none, none_err, none_info = state_manager.load_session()
	eq(none, nil, "all corrupt")
	truthy(none_err, "all corrupt message")
	eq(none_info.kind, "corrupt", "all corrupt kind")
	for _, name in ipairs(names(session_dir)) do
		eq(read(utils.join_path(session_dir, name)), "not json", "damaged file untouched")
	end
	local next_after_corrupt = truthy(state_manager.save_session(session(1, { marker = "fresh" })))
	local max = 0
	for _, name in ipairs(names(session_dir)) do
		max = math.max(max, tonumber(name:match("^snapshot%-(%d+)%.json$")) or 0)
	end
	eq(next_after_corrupt, snapshot(max), "published as highest generation")
	eq(max > 9, true, "numbering never reuses a corrupt generation")

	-- Only exact 20-digit names are generations.
	write(utils.join_path(session_dir, "snapshot-0000000000000000099.json"), "{}")
	write(utils.join_path(session_dir, "snapshot-000000000000000000099.json"), "{}")
	local after_odd = truthy(state_manager.save_session(session(1, { marker = "odd" })))
	eq(after_odd, snapshot(max + 1), "other-width numbers never become generations")

	-- An unreadable (not merely missing) session folder is an error that
	-- touches nothing: every existing snapshot stays.
	local files_before_denied = names(session_dir)
	local function same_dir(a, b)
		return a:gsub("\\", "/"):lower() == b:gsub("\\", "/"):lower()
	end
	local real_read_dir = wezterm.read_dir
	wezterm.read_dir = function(path)
		if same_dir(path, session_dir) then
			error("access denied")
		end
		return real_read_dir(path)
	end
	local denied_path, denied_err = state_manager.save_session(session(1, { marker = "denied" }))
	local denied_state, denied_load_err, denied_info = state_manager.load_session()
	local denied_records, denied_list_err = state_manager.list_sessions()
	wezterm.read_dir = real_read_dir
	eq(denied_path, nil, "save refused when the folder cannot be listed")
	truthy(denied_err and denied_err:find("access denied", 1, true), "save reports the listing error")
	eq(denied_state, nil, "load does not report a fresh start")
	truthy(denied_load_err, "load reports the listing error")
	eq(denied_info.kind, "corrupt", "load is not 'missing'")
	eq(#denied_records, 0, "no records listed")
	truthy(denied_list_err and denied_list_err:find("access denied", 1, true), "listing reports the error")
	local files_after_denied = names(session_dir)
	eq(#files_after_denied, #files_before_denied, "no snapshot lost or added")
end

-- Encryption never silently writes plaintext snapshots.
do
	local isolated = utils.join_path(root, "encrypted")
	eq(state_manager.change_state_save_dir(isolated), true, "encrypted root")
	file_io.encryption.enable = true
	local path, err = state_manager.save_session(session(1))
	local loaded, load_err, info = state_manager.load_session()
	local records, list_err = state_manager.list_sessions()
	file_io.encryption.enable = false
	local expected = "Session snapshots do not support encryption; disable session saving or disable resurrect encryption"
	eq(path, nil, "encrypted save refused")
	eq(err, expected, "encrypted save message")
	eq(loaded, nil, "encrypted load refused")
	eq(load_err, expected, "encrypted load message")
	eq(info.kind, "encrypted", "encrypted kind")
	eq(#records, 0, "encrypted listing empty")
	eq(list_err, expected, "encrypted listing message")
	eq(names(isolated), nil, "nothing was written")
end

-- A file where the state directory must be: real error, nothing overwritten.
do
	local blocker = utils.join_path(root, "blocker")
	write(blocker, "keep")
	eq(state_manager.change_state_save_dir(utils.join_path(blocker, "state")), true, "blocked root")
	local path, err = state_manager.save_session(session(1))
	eq(path, nil, "blocked save")
	truthy(err and err ~= "", "blocked save message")
	eq(read(blocker), "keep", "blocker untouched")
	local named, named_err = state_manager.save_state({ title = "t", pane_tree = {} })
	eq(named, nil, "blocked named save")
	truthy(named_err, "blocked named save message")
end

-- current_state and startup restoration -----------------------------------

do
	eq(state_manager.change_state_save_dir(utils.join_path(root, "startup")), true, "startup root")
	local restored
	package.loaded["resurrect.workspace_state"] = {
		restore_workspace = function(state, opts)
			restored = { state = state, opts = opts }
			return {}
		end,
	}
	package.loaded["resurrect.tab_state"] = { default_on_pane_restore = function() end }

	local ok, err = state_manager.resurrect_on_gui_startup()
	eq(ok, nil, "startup without a pointer")
	truthy(err, "startup without a pointer message")

	truthy(state_manager.save_state({ workspace = "my/ws", window_states = {}, mark = 1 }))
	truthy(state_manager.write_current_state("my/ws", "workspace"))
	local started, start_err = state_manager.resurrect_on_gui_startup()
	truthy(started, "startup restore: " .. tostring(start_err))
	eq(restored.state.mark, 1, "restored the pointed-to workspace")
	eq(restored.opts.spawn_in_workspace, true, "restore into its workspace")

	package.loaded["resurrect.workspace_state"].restore_workspace = function()
		return nil, "boom"
	end
	local bad, bad_err = state_manager.resurrect_on_gui_startup()
	eq(bad, nil, "restore failure propagated")
	truthy(bad_err:find("boom", 1, true), "restore failure message")

	eq((state_manager.write_current_state("x", "../y")), nil, "bad type rejected")
end

-- Fuzzy loader lists decoded names and literal IDs without any shell -----------

do
	local fuzzy_root = utils.join_path(root, "fuzzy")
	eq(state_manager.change_state_save_dir(fuzzy_root), true, "fuzzy root")
	truthy(state_manager.save_state({ workspace = "work/space", window_states = {} }))
	truthy(state_manager.save_state({ title = "tab one", pane_tree = {} }))
	truthy(state_manager.save_state({ title = "win é", tabs = {} }))
	write(utils.join_path(fuzzy_root, "workspace", "legacy+name.json"), "{}")

	local identity = function(label)
		return label
	end
	local choices = fuzzy_loader.list_choices({
		show_state_with_date = true,
		fmt_workspace = identity,
		fmt_window = identity,
		fmt_tab = identity,
		fmt_date = identity,
	})

	local by_id = {}
	for _, choice in ipairs(choices) do
		by_id[choice.id] = choice.label
	end
	local workspace_id = "workspace/" .. utils.encode_state_name("work/space") .. ".json"
	truthy(by_id[workspace_id], "workspace listed under its literal ID")
	truthy(by_id[workspace_id]:find("work/space.json", 1, true), "decoded workspace label")
	truthy(by_id[workspace_id]:find(os.date("%Y"), 1, true), "saved_at date shown")
	truthy(by_id["tab/" .. utils.encode_state_name("tab one") .. ".json"], "tab listed")
	truthy(by_id["window/" .. utils.encode_state_name("win é") .. ".json"], "window listed")
	eq(#choices, 3, "foreign files are not listed")

	-- The listed ID round-trips through the real loader.
	local state_type, name = state_manager.parse_state_id(workspace_id)
	eq(state_manager.load_state(name, state_type).workspace, "work/space", "ID loads its state")
end
