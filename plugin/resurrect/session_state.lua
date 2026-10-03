local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local window_state_mod = require("resurrect.window_state")
local tab_state_mod = require("resurrect.tab_state")
local pane_tree_mod = require("resurrect.pane_tree")

local pub = {}

pub.FORMAT_VERSION = 1

local function is_integer(v)
	return type(v) == "number" and v == math.floor(v)
end

---Validates a full-session snapshot. `generation` and `saved_at` are assigned by the
---storage layer, so they are only checked when present.
---@param state any
---@return boolean|nil ok
---@return string|nil err
function pub.validate(state)
	if type(state) ~= "table" then
		return nil, "session state is not a table"
	end
	if state.format_version ~= pub.FORMAT_VERSION then
		return nil, "unsupported session format version " .. tostring(state.format_version)
	end
	if state.generation ~= nil and (not is_integer(state.generation) or state.generation < 1) then
		return nil, "session generation must be a positive integer"
	end
	if state.saved_at ~= nil and (not is_integer(state.saved_at) or state.saved_at < 0) then
		return nil, "session saved_at must be a Unix timestamp"
	end
	if type(state.active_workspace) ~= "string" or state.active_workspace == "" then
		return nil, "session active_workspace must be a non-empty string"
	end
	local windows = state.windows
	if type(windows) ~= "table" or #windows == 0 then
		return nil, "session has no windows"
	end
	local has_active_workspace = false
	for i, window_state in ipairs(windows) do
		local ok, err = window_state_mod.validate(window_state)
		if not ok then
			return nil, "window " .. i .. ": " .. err
		end
		if type(window_state.workspace) ~= "string" or window_state.workspace == "" then
			return nil, "window " .. i .. ": workspace must be a non-empty string"
		end
		if window_state.workspace == state.active_workspace then
			has_active_workspace = true
		end
	end
	if not has_active_workspace then
		return nil, "no window belongs to the active workspace"
	end
	if state.active_window ~= nil then
		if not is_integer(state.active_window) or state.active_window < 1 or state.active_window > #windows then
			return nil, "session active_window does not identify a saved window"
		end
		if windows[state.active_window].workspace ~= state.active_workspace then
			return nil, "session active_window is not in the active workspace"
		end
	end
	return true
end

---Window, tab and pane totals of a (valid) session snapshot.
---@param state session_state
---@return {windows: integer, tabs: integer, panes: integer}
function pub.counts(state)
	local counts = { windows = 0, tabs = 0, panes = 0 }
	for _, window_state in ipairs(state.windows or {}) do
		counts.windows = counts.windows + 1
		for _, tab_state in ipairs(window_state.tabs or {}) do
			counts.tabs = counts.tabs + 1
			counts.panes = counts.panes + #pane_tree_mod.leaves(tab_state.pane_tree)
		end
	end
	return counts
end

---Mux ID of the focused GUI window, if one can be determined.
---@return integer|nil
local function focused_window_id()
	local ok, id = pcall(function()
		for _, gui_window in ipairs(wezterm.gui.gui_windows()) do
			if gui_window:is_focused() then
				return gui_window:window_id()
			end
		end
	end)
	if ok then
		return id
	end
end

---Captures every mux window of every workspace.
---Returns nil and an error unless the whole session was captured.
---@param opts? pane_capture_opts|{focused_window_id: integer|nil}
---@return session_state|nil
---@return string|nil err
function pub.capture(opts)
	opts = opts or {}
	local ok, state, err = pcall(function()
		local mux_windows = wezterm.mux.all_windows()
		table.sort(mux_windows, function(a, b)
			return a:window_id() < b:window_id()
		end)
		if #mux_windows == 0 then
			return nil, "there are no windows to save"
		end

		local active_workspace = wezterm.mux.get_active_workspace()
		local focused = opts.focused_window_id or focused_window_id()
		local session = {
			format_version = pub.FORMAT_VERSION,
			active_workspace = active_workspace,
			windows = {},
		}
		for i, mux_window in ipairs(mux_windows) do
			local window_state, window_err = window_state_mod.get_window_state(mux_window, opts)
			if not window_state then
				return nil, "window " .. i .. ": " .. tostring(window_err)
			end
			session.windows[i] = window_state
			if
				focused ~= nil
				and mux_window:window_id() == focused
				and window_state.workspace == active_workspace
			then
				session.active_window = i
			end
		end
		local valid, valid_err = pub.validate(session)
		if not valid then
			return nil, "captured session is invalid: " .. tostring(valid_err)
		end
		return session
	end)
	if not ok then
		return nil, "session capture failed: " .. tostring(state)
	end
	if not state then
		return nil, err
	end
	return state
end

---@param state session_state
---@param opts table
---@param restored MuxWindow[]
---@return string selected workspace
local function restore_impl(state, opts, restored)
	local names = opts.workspace_names or {}
	local first_workspace, selected, focus_window

	for i, window_state in ipairs(state.windows) do
		local target = names[window_state.workspace] or window_state.workspace
		first_workspace = first_workspace or target

		local root_leaf = pane_tree_mod.first_leaf(window_state.tabs[1].pane_tree)
		local cmd, notice = tab_state_mod.spawn_args(root_leaf, opts)
		cmd.width = window_state.size.cols
		cmd.height = window_state.size.rows
		cmd.workspace = target

		local window_opts = {}
		for k, v in pairs(opts) do
			window_opts[k] = v
		end
		window_opts.close_open_tabs, window_opts.close_open_panes = false, false
		window_opts.tab, window_opts.pane, window_opts.window = wezterm.mux.spawn_window(cmd)
		window_opts.root_notice = notice
		restored[#restored + 1] = window_opts.window

		local ok, err = window_state_mod.restore_window(window_opts.window, window_state, window_opts)
		if not ok then
			error(err, 0)
		end
		if state.active_window == i then
			focus_window = window_opts.window
		end
	end

	selected = names[state.active_workspace] or state.active_workspace or first_workspace
	wezterm.mux.set_active_workspace(selected)
	if focus_window then
		pcall(function()
			focus_window:gui_window():focus()
		end)
	end
	return selected
end

---Restores a captured session additively: every saved window is created anew and the
---decoded state is never modified. `opts.workspace_names` maps original workspace names
---to the names to create instead.
---@param state session_state
---@param opts? restore_opts|{workspace_names: table<string,string>|nil}
---@return MuxWindow[]|nil windows
---@return string|nil err
---@return MuxWindow[]|nil partial  windows created before a failure
function pub.restore(state, opts)
	local valid, validation_err = pub.validate(state)
	if not valid then
		return nil, validation_err
	end
	local o, owner = tab_state_mod.begin_restore(opts)
	wezterm.emit("resurrect.session_state.restore.start")
	local restored = {}
	local success, result = pcall(restore_impl, state, o, restored)
	tab_state_mod.finish_restore(o, owner)
	if not success then
		return nil, tostring(result), restored
	end
	wezterm.emit("resurrect.session_state.restore.finished")
	return restored
end

return pub
