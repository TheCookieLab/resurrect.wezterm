local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local window_state_mod = require("resurrect.window_state")
local tab_state_mod = require("resurrect.tab_state")
local pane_tree_mod = require("resurrect.pane_tree")

local pub = {}

---Validates a workspace state before anything is spawned.
---@param workspace_state any
---@return boolean|nil ok
---@return string|nil err
function pub.validate(workspace_state)
	if type(workspace_state) ~= "table" then
		return nil, "workspace state is not a table"
	end
	if type(workspace_state.workspace) ~= "string" or workspace_state.workspace == "" then
		return nil, "workspace name must be a non-empty string"
	end
	local windows = workspace_state.window_states
	if type(windows) ~= "table" or #windows == 0 then
		return nil, "workspace has no windows"
	end
	for i, window_state in ipairs(windows) do
		local ok, err = window_state_mod.validate(window_state)
		if not ok then
			return nil, "window " .. i .. ": " .. err
		end
	end
	return true
end

---@return MuxWindow[]
local function restore_workspace_impl(workspace_state, opts, restored)
	local target = opts.workspace_name or workspace_state.workspace

	for i, window_state in ipairs(workspace_state.window_states) do
		local window_opts = {}
		for k, v in pairs(opts) do
			window_opts[k] = v
		end
		window_opts.tab, window_opts.pane, window_opts.window, window_opts.root_notice = nil, nil, nil, nil

		if i == 1 and opts.window then
			window_opts.window = opts.window
			if opts.spawn_in_workspace then
				-- only the explicitly reused window moves; other windows are untouched
				opts.window:set_workspace(target)
			end
			if not opts.close_open_tabs then
				window_opts.tab = opts.window:active_tab()
				if not opts.close_open_panes then
					window_opts.pane = opts.window:active_pane()
				end
			end
		else
			local root_leaf = pane_tree_mod.first_leaf(window_state.tabs[1].pane_tree)
			local cmd, notice = tab_state_mod.spawn_args(root_leaf, opts)
			cmd.width = window_state.size.cols
			cmd.height = window_state.size.rows
			if opts.spawn_in_workspace then
				cmd.workspace = target
			end
			window_opts.tab, window_opts.pane, window_opts.window = wezterm.mux.spawn_window(cmd)
			window_opts.root_notice = notice
		end
		restored[#restored + 1] = window_opts.window

		local ok, err = window_state_mod.restore_window(window_opts.window, window_state, window_opts)
		if not ok then
			error(err, 0)
		end
	end

	if opts.spawn_in_workspace then
		wezterm.mux.set_active_workspace(target)
	end
end

---restore workspace state
---@param workspace_state workspace_state
---@param opts? restore_opts
---@return MuxWindow[]|nil windows  windows that were restored or reused
---@return string|nil err
---@return MuxWindow[]|nil partial  windows created before a failure
function pub.restore_workspace(workspace_state, opts)
	local ok, err = pub.validate(workspace_state)
	if not ok then
		return nil, err
	end

	local o, owner = tab_state_mod.begin_restore(opts)
	wezterm.emit("resurrect.workspace_state.restore_workspace.start")
	local restored = {}
	local success, result = pcall(restore_workspace_impl, workspace_state, o, restored)
	tab_state_mod.finish_restore(o, owner)
	if not success then
		return nil, tostring(result), restored
	end
	wezterm.emit("resurrect.workspace_state.restore_workspace.finished")
	return restored
end

---Returns the state of the current workspace, or nil and an error
---@param opts? pane_capture_opts
---@return workspace_state|nil
---@return string|nil err
function pub.get_workspace_state(opts)
	local workspace = wezterm.mux.get_active_workspace()
	local windows = {}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		if mux_win:get_workspace() == workspace then
			windows[#windows + 1] = mux_win
		end
	end
	table.sort(windows, function(a, b)
		return a:window_id() < b:window_id()
	end)
	if #windows == 0 then
		return nil, "workspace " .. tostring(workspace) .. " has no windows"
	end

	local workspace_state = { workspace = workspace, window_states = {} }
	for i, mux_win in ipairs(windows) do
		local window_state, err = window_state_mod.get_window_state(mux_win, opts)
		if not window_state then
			return nil, "window " .. i .. ": " .. tostring(err)
		end
		workspace_state.window_states[i] = window_state
	end
	return workspace_state
end

return pub
