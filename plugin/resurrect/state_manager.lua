local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local file_io = require("resurrect.file_io")
local utils = require("resurrect.utils")

local pub = {}

--- Directory that holds the `workspace`, `window`, `tab` and `session` folders.
--- Set it with `change_state_save_dir`; nothing is saved until then.
---@type string|nil
pub.save_state_dir = nil

local STATE_TYPES = { workspace = true, window = true, tab = true }

local SESSION_ENCRYPTION_ERROR =
	"Session snapshots do not support encryption; disable session saving or disable resurrect encryption"

local SNAPSHOT_KEEP = 3

---@param message string
---@return nil
---@return string
local function fail(message)
	wezterm.emit("resurrect.error", message)
	wezterm.log_error(message)
	return nil, message
end

---@return string|nil dir
---@return string|nil error
local function state_dir()
	if type(pub.save_state_dir) ~= "string" or pub.save_state_dir == "" then
		return nil, "No state directory is configured; call state_manager.change_state_save_dir(directory) first"
	end
	return pub.save_state_dir
end

---@param state_type string
---@param name string
---@return string|nil path
---@return string|nil error
local function get_file_path(state_type, name)
	if not STATE_TYPES[state_type] then
		return nil, "Unsupported state type: " .. tostring(state_type)
	end
	if type(name) ~= "string" then
		return nil, "State name must be a string, got " .. type(name)
	end
	local dir, err = state_dir()
	if not dir then
		return nil, err
	end
	return utils.join_path(dir, state_type, utils.encode_state_name(name) .. ".json")
end

---Split a state ID such as "workspace/s-6d61696e.json" (as handed to the
---fuzzy loader callback) into its type and the original, decoded name.
---@param id string
---@return "workspace"|"window"|"tab"|nil type
---@return string|nil name_or_error
function pub.parse_state_id(id)
	if type(id) ~= "string" then
		return nil, "State ID must be a string"
	end
	local state_type, stem = id:match("^(%a+)/([^/\\]+)%.json$")
	if not state_type or not STATE_TYPES[state_type] then
		return nil, "Not a state ID: " .. id
	end
	local name = utils.decode_state_name(stem)
	if not name then
		return nil, "Not a state ID: " .. id
	end
	return state_type, name
end

---@param state table
---@return "workspace"|"window"|"tab"|nil type
---@return string|nil name_or_error
local function classify(state)
	if type(state) ~= "table" then
		return nil, "State must be a table"
	end
	if state.window_states then
		return "workspace", state.workspace
	elseif state.tabs then
		return "window", state.title
	elseif state.pane_tree then
		return "tab", state.title
	end
	return nil, "State is not a workspace, window or tab state"
end

---save state to a file
---@param state workspace_state | window_state | tab_state
---@param opt_name? string
---@return string|nil path the file that was written
---@return string|nil error
function pub.save_state(state, opt_name)
	local state_type, name = classify(state)
	if not state_type then
		return fail("Cannot save state: " .. tostring(name))
	end
	if opt_name ~= nil then
		name = opt_name
	end
	if type(name) ~= "string" then
		return fail("Cannot save " .. state_type .. " state: it has no name")
	end
	local path, path_err = get_file_path(state_type, name)
	if not path then
		return fail(path_err)
	end
	local folder_ok, folder_err = utils.ensure_folder_exists(utils.dirname(path))
	if not folder_ok then
		return fail(folder_err)
	end

	local stamped = {}
	for key, value in pairs(state) do
		stamped[key] = value
	end
	stamped.saved_at = os.time()

	local ok, err = file_io.write_state(path, stamped, state_type)
	if not ok then
		return nil, err
	end
	return path
end

---Reads a file with the state. A valid previous version is used when the
---current file is damaged, in which case the second result describes why.
---@param name string
---@param state_type string
---@return table|nil state
---@return string|nil warning_or_error
function pub.load_state(name, state_type)
	wezterm.emit("resurrect.state_manager.load_state.start", name, state_type)
	local path, path_err = get_file_path(state_type, name)
	if not path then
		return fail(path_err)
	end
	local state, message, kind = file_io.load_state_file(path)
	if not state then
		return fail(message)
	end
	if kind == "backup" then
		wezterm.emit("resurrect.error", message)
		wezterm.log_warn(message)
	end
	wezterm.emit("resurrect.state_manager.load_state.finished", name, state_type)
	return state, kind == "backup" and message or nil
end

---Saves the stater after interval in seconds
---@param opts? { interval_seconds: integer?, save_workspaces: boolean?, save_windows: boolean?, save_tabs: boolean? }
function pub.periodic_save(opts)
	if opts == nil then
		opts = { save_workspaces = true }
	end
	if opts.interval_seconds == nil then
		opts.interval_seconds = 60 * 15
	end

	local function save_captured(state, capture_err)
		if not state then
			fail("Periodic save: " .. tostring(capture_err))
			return
		end
		pub.save_state(state)
	end

	wezterm.time.call_after(opts.interval_seconds, function()
		local ok, err = pcall(function()
			wezterm.emit("resurrect.state_manager.periodic_save.start", opts)
			if opts.save_workspaces then
				save_captured(require("resurrect.workspace_state").get_workspace_state())
			end

			if opts.save_windows then
				for _, gui_win in ipairs(wezterm.gui.gui_windows()) do
					local mux_win = gui_win:mux_window()
					local title = mux_win:get_title()
					if title ~= "" and title ~= nil then
						save_captured(require("resurrect.window_state").get_window_state(mux_win))
					end
				end
			end

			if opts.save_tabs then
				for _, gui_win in ipairs(wezterm.gui.gui_windows()) do
					local mux_win = gui_win:mux_window()
					for _, mux_tab in ipairs(mux_win:tabs()) do
						local title = mux_tab:get_title()
						if title ~= "" and title ~= nil then
							save_captured(require("resurrect.tab_state").get_tab_state(mux_tab))
						end
					end
				end
			end

			wezterm.emit("resurrect.state_manager.periodic_save.finished", opts)
		end)
		if not ok then
			fail("Periodic save failed: " .. tostring(err))
		end
		pub.periodic_save(opts)
	end)
end

---Writes the current state name and type
---@param name string
---@param state_type string
---@return true|nil
---@return string|nil
function pub.write_current_state(name, state_type)
	if not STATE_TYPES[state_type] then
		return nil, "Unsupported state type: " .. tostring(state_type)
	end
	if type(name) ~= "string" then
		return nil, "State name must be a string, got " .. type(name)
	end
	local dir, dir_err = state_dir()
	if not dir then
		return nil, dir_err
	end
	local folder_ok, folder_err = utils.ensure_folder_exists(dir)
	if not folder_ok then
		return nil, folder_err
	end
	return file_io.write_file(
		utils.join_path(dir, "current_state"),
		string.format("%s\n%s", utils.encode_state_name(name), state_type)
	)
end

---callback for resurrecting workspaces on startup
---@return true|nil
---@return string|nil
function pub.resurrect_on_gui_startup()
	local dir, dir_err = state_dir()
	if not dir then
		return nil, dir_err
	end
	local text, read_err = file_io.read_file(utils.join_path(dir, "current_state"))
	if not text then
		return nil, read_err
	end
	local stem, state_type = text:match("^([^\r\n]*)\r?\n([^\r\n]*)")
	local name = stem and utils.decode_state_name(stem)
	if not name or not STATE_TYPES[state_type] then
		return fail("The current_state file is malformed: " .. utils.join_path(dir, "current_state"))
	end
	if state_type ~= "workspace" then
		return true
	end

	local state, load_err = pub.load_state(name, state_type)
	if not state then
		return nil, load_err
	end
	local ok, restored, restore_err = pcall(require("resurrect.workspace_state").restore_workspace, state, {
		spawn_in_workspace = true,
		relative = true,
		restore_text = true,
		on_pane_restore = require("resurrect.tab_state").default_on_pane_restore,
	})
	if not ok then
		return fail("Could not restore workspace: " .. tostring(restored))
	end
	if not restored then
		return fail("Could not restore workspace: " .. tostring(restore_err))
	end
	return true
end

---Delete a saved state by its ID, e.g. "workspace/s-6d61696e.json", and its backup.
---@param id string
---@return true|nil
---@return string|nil
function pub.delete_state(id)
	wezterm.emit("resurrect.state_manager.delete_state.start", id)
	local state_type, name = pub.parse_state_id(id)
	if not state_type then
		return fail("Failed to delete state: " .. tostring(name))
	end
	local path, path_err = get_file_path(state_type, name)
	if not path then
		return fail("Failed to delete state: " .. path_err)
	end
	local removed, remove_err = os.remove(path)
	if not removed then
		return fail("Failed to delete state " .. path .. ": " .. tostring(remove_err))
	end
	local backup = path .. ".bak"
	if file_io.path_exists(backup) then
		local backup_removed, backup_err = os.remove(backup)
		if not backup_removed then
			return fail("Deleted " .. path .. " but could not delete its backup: " .. tostring(backup_err))
		end
	end
	wezterm.emit("resurrect.state_manager.delete_state.finished", id)
	return true
end

--- Merges user-supplied options with default options
--- @param user_opts encryption_opts
function pub.set_encryption(user_opts)
	require("resurrect.file_io").set_encryption(user_opts)
end

---Changes the directory to save the state to. This only records the directory;
---folders are created when something is first saved.
---@param directory string
---@return true|nil
---@return string|nil
function pub.change_state_save_dir(directory)
	if type(directory) ~= "string" or directory == "" then
		return nil, "The state directory must be a non-empty string"
	end
	pub.save_state_dir = directory
	return true
end

function pub.set_max_nlines(max_nlines)
	require("resurrect.pane_tree").max_nlines = max_nlines
end

-- Full-session snapshots ----------------------------------------------------

---The folder holding the numbered session snapshots.
---@return string|nil
---@return string|nil error
function pub.session_dir()
	local dir, err = state_dir()
	if not dir then
		return nil, err
	end
	return utils.join_path(dir, "session")
end

---@param generation integer
---@return string
local function snapshot_name(generation)
	return string.format("snapshot-%020d.json", generation)
end

-- The generation encoded in a snapshot file name: exactly 20 digits, so that
-- snapshot_name(generation) reproduces the name. Anything else is not ours.
---@param name string
---@return integer|nil
local function snapshot_generation(name)
	local digits = name:match("^snapshot%-(" .. string.rep("%d", 20) .. ")%.json$")
	local generation = digits and tonumber(digits)
	if math.type(generation) == "integer" then
		return generation
	end
end

-- Numbered snapshot files in `dir`, newest first. Temp, backup and quarantined
-- files never match. A folder that does not exist yet is an empty list; one that
-- exists but cannot be listed is an error.
---@param dir string
---@return { generation: integer, path: string }[]|nil
---@return string|nil error
local function list_generations(dir)
	local ok, entries = pcall(wezterm.read_dir, dir)
	if not ok then
		local state, state_err = utils.directory_state(dir)
		if state ~= "missing" then
			return nil, state_err or ("Cannot read session folder " .. dir .. ": " .. tostring(entries))
		end
		return {}
	end
	local generations = {}
	for _, entry in ipairs(entries) do
		local generation = snapshot_generation(utils.basename(entry))
		if generation then
			table.insert(generations, { generation = generation, path = utils.join_path(dir, snapshot_name(generation)) })
		end
	end
	table.sort(generations, function(a, b)
		return a.generation > b.generation
	end)
	return generations
end

---@param path string
---@return table|nil state
---@return string|nil error
local function read_snapshot(path)
	local state, err = file_io.load_plain_json(path)
	if not state then
		return nil, err
	end
	local valid, validation_err = require("resurrect.session_state").validate(state)
	if not valid then
		return nil, path .. ": " .. tostring(validation_err)
	end
	return state
end

-- Keep the newest few valid snapshots; older valid ones are deleted. Damaged
-- files are never touched.
---@param dir string
---@return string|nil warning
local function prune_snapshots(dir)
	local candidates, list_err = list_generations(dir)
	if not candidates then
		return "Could not prune old session snapshots: " .. tostring(list_err)
	end
	local kept = 0
	local problems = {}
	for _, candidate in ipairs(candidates) do
		if read_snapshot(candidate.path) then
			kept = kept + 1
			if kept > SNAPSHOT_KEEP then
				local removed, err = os.remove(candidate.path)
				if not removed then
					table.insert(problems, tostring(err))
				end
			end
		end
	end
	if #problems > 0 then
		return "Could not remove old session snapshots: " .. table.concat(problems, "; ")
	end
end

---Publish a full-session snapshot as the next immutable generation.
---@param state table session_state
---@return string|nil path
---@return string|nil error_or_warning  error when path is nil; otherwise a non-fatal cleanup warning
function pub.save_session(state)
	if file_io.encryption.enable then
		return nil, SESSION_ENCRYPTION_ERROR
	end
	local session_state = require("resurrect.session_state")
	local valid, validation_err = session_state.validate(state)
	if not valid then
		return nil, "Refusing to save an invalid session: " .. tostring(validation_err)
	end
	local dir, dir_err = pub.session_dir()
	if not dir then
		return nil, dir_err
	end
	local folder_ok, folder_err = utils.ensure_folder_exists(dir)
	if not folder_ok then
		return nil, folder_err
	end

	local existing, list_err = list_generations(dir)
	if not existing then
		return nil, list_err
	end
	local generation = (existing[1] and existing[1].generation or 0) + 1
	local destination = utils.join_path(dir, snapshot_name(generation))
	if file_io.path_exists(destination) then
		return nil, "Session snapshot already exists: " .. destination
	end

	local stamped = {}
	for key, value in pairs(state) do
		stamped[key] = value
	end
	stamped.generation = generation
	stamped.saved_at = os.time()
	local stamped_ok, stamped_err = session_state.validate(stamped)
	if not stamped_ok then
		return nil, "Refusing to save an invalid session: " .. tostring(stamped_err)
	end
	local json, encode_err = file_io.encode_json(stamped)
	if not json then
		return nil, encode_err
	end

	local temp, stage_err = file_io.stage_plain_json(destination, json, function(parsed)
		if parsed.generation ~= generation then
			return nil, "snapshot generation changed while writing"
		end
		return session_state.validate(parsed)
	end)
	if not temp then
		return nil, stage_err
	end
	local renamed, rename_err = os.rename(temp, destination)
	if not renamed then
		return nil, file_io.discard_temp(temp, "Could not publish " .. destination .. ": " .. tostring(rename_err))
	end
	return destination, prune_snapshots(dir)
end

---Load a session snapshot: the newest valid one, falling back to older ones,
---or exactly `path` (a path returned by `save_session` or `list_sessions`).
---A missing session is not an error: nil, nil, { kind = "missing" }.
---Unusable files give nil, message, { kind = "corrupt" | "encrypted" }.
---On success: state, warning|nil, { path, generation, kind = "primary" | "fallback" }.
---@param path? string
---@return table|nil state
---@return string|nil warning_or_error
---@return table info
function pub.load_session(path)
	if file_io.encryption.enable then
		return nil, SESSION_ENCRYPTION_ERROR, { kind = "encrypted" }
	end
	local dir, dir_err = pub.session_dir()
	if not dir then
		return nil, dir_err, { kind = "corrupt" }
	end

	if path ~= nil then
		local generation = type(path) == "string" and snapshot_generation(utils.basename(path))
		local expected = generation and utils.join_path(dir, utils.basename(path))
		local function normal(value)
			value = value:gsub("\\", "/")
			return utils.is_windows and value:lower() or value
		end
		if not expected or normal(expected) ~= normal(path) then
			return nil, "Not a session snapshot of this state directory: " .. tostring(path), { kind = "corrupt" }
		end
		local state, err, kind = file_io.load_plain_json(expected)
		if not state and kind == "missing" then
			return nil, nil, { kind = "missing" }
		end
		if state then
			local valid, validation_err = require("resurrect.session_state").validate(state)
			if not valid then
				state, err = nil, expected .. ": " .. tostring(validation_err)
			end
		end
		if not state then
			return nil, err, { kind = "corrupt" }
		end
		return state, nil, { path = expected, generation = generation, kind = "primary" }
	end

	local candidates, list_err = list_generations(dir)
	if not candidates then
		return nil, list_err, { kind = "corrupt" }
	end
	if #candidates == 0 then
		return nil, nil, { kind = "missing" }
	end
	local failures = {}
	for _, candidate in ipairs(candidates) do
		local state, err = read_snapshot(candidate.path)
		if state then
			local info = { path = candidate.path, generation = candidate.generation, kind = "primary" }
			if #failures == 0 then
				return state, nil, info
			end
			info.kind = "fallback"
			return state,
				"Recovered the previous valid session snapshot because the newer one is unusable: "
					.. table.concat(failures, "; "),
				info
		end
		table.insert(failures, tostring(err))
	end
	return nil, "No valid session snapshot could be loaded: " .. table.concat(failures, "; "), { kind = "corrupt" }
end

---Every valid session snapshot, newest first, already decoded. Records are
---`{ id = <immutable path>, state, generation, saved_at, windows, tabs, panes }`.
---Unusable files are left out and summarised once in the second result.
---@return table[] records
---@return string|nil warning
function pub.list_sessions()
	if file_io.encryption.enable then
		return {}, SESSION_ENCRYPTION_ERROR
	end
	local dir, dir_err = pub.session_dir()
	if not dir then
		return {}, dir_err
	end
	local session_state = require("resurrect.session_state")
	local records = {}
	local failures = {}
	local candidates, list_err = list_generations(dir)
	if not candidates then
		return {}, list_err
	end
	for _, candidate in ipairs(candidates) do
		local state, err = read_snapshot(candidate.path)
		if state then
			local counts = session_state.counts(state)
			table.insert(records, {
				id = candidate.path,
				state = state,
				generation = candidate.generation,
				saved_at = state.saved_at,
				windows = counts.windows,
				tabs = counts.tabs,
				panes = counts.panes,
			})
		else
			table.insert(failures, tostring(err))
		end
	end
	local warning
	if #failures > 0 then
		warning = string.format(
			"Ignored %d unusable session snapshot(s): %s",
			#failures,
			table.concat(failures, "; ")
		)
	end
	return records, warning
end

return pub
