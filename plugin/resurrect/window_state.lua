local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local tab_state_mod = require("resurrect.tab_state")
local pane_tree_mod = require("resurrect.pane_tree")
local pub = {}

local function is_positive_int(v)
	return type(v) == "number" and v == math.floor(v) and v >= 1
end

---Validates a window state before anything is spawned.
---@param window_state any
---@return boolean|nil ok
---@return string|nil err
function pub.validate(window_state)
	if type(window_state) ~= "table" then
		return nil, "window state is not a table"
	end
	if window_state.title ~= nil and type(window_state.title) ~= "string" then
		return nil, "window title must be a string"
	end
	if window_state.workspace ~= nil and (type(window_state.workspace) ~= "string" or window_state.workspace == "") then
		return nil, "window workspace must be a non-empty string"
	end
	local size = window_state.size
	if type(size) ~= "table" or not is_positive_int(size.cols) or not is_positive_int(size.rows) then
		return nil, "window size must provide positive cols and rows"
	end
	local tabs = window_state.tabs
	if type(tabs) ~= "table" or #tabs == 0 then
		return nil, "window has no tabs"
	end
	local active = 0
	for i, tab_state in ipairs(tabs) do
		local ok, err = tab_state_mod.validate(tab_state)
		if not ok then
			return nil, "tab " .. i .. ": " .. err
		end
		if tab_state.is_active then
			active = active + 1
		end
	end
	if active > 1 then
		return nil, "window has more than one active tab"
	end
	return true
end

---Returns the state of the window, or nil and an error
---@param window MuxWindow
---@param opts? pane_capture_opts
---@return window_state|nil
---@return string|nil err
function pub.get_window_state(window, opts)
	local ok, state, err = pcall(function()
		local tabs = window:tabs_with_info()
		if #tabs == 0 then
			return nil, "window has no tabs"
		end

		local window_state = {
			title = window:get_title(),
			workspace = window:get_workspace(),
			tabs = {},
		}
		for i, tab in ipairs(tabs) do
			local tab_state, tab_err = tab_state_mod.get_tab_state(tab.tab, opts)
			if not tab_state then
				return nil, "tab " .. i .. ": " .. tostring(tab_err)
			end
			tab_state.is_active = tab.is_active == true
			window_state.tabs[i] = tab_state
		end

		local size = tabs[1].tab:get_size()
		window_state.size = {
			cols = size.cols,
			rows = size.rows,
			pixel_width = size.pixel_width,
			pixel_height = size.pixel_height,
			dpi = size.dpi,
		}
		return window_state
	end)
	if not ok then
		return nil, "window capture failed: " .. tostring(state)
	end
	if not state then
		return nil, err
	end
	return state
end

---Force closes all other tabs in the window but one
---@param window MuxWindow
---@param tab_to_keep MuxTab
local function close_all_other_tabs(window, tab_to_keep)
	for _, tab in ipairs(window:tabs()) do
		if tab:tab_id() ~= tab_to_keep:tab_id() then
			tab:activate()
			window
				:gui_window()
				:perform_action(wezterm.action.CloseCurrentTab({ confirm = false }), window:active_pane())
		end
	end
end

---@return true
local function restore_window_impl(window, window_state, opts)
	if window_state.title and window_state.title ~= "" then
		window:set_title(window_state.title)
	end

	local active_tab, first_tab
	for i, tab_state in ipairs(window_state.tabs) do
		local tab_opts = {}
		for k, v in pairs(opts) do
			tab_opts[k] = v
		end
		tab_opts.tab, tab_opts.pane, tab_opts.root_notice = nil, nil, nil

		local tab
		if i == 1 and opts.tab then
			tab = opts.tab
			tab_opts.pane = opts.pane
			tab_opts.root_notice = opts.root_notice
		else
			local root_leaf = pane_tree_mod.first_leaf(tab_state.pane_tree)
			local cmd, notice = tab_state_mod.spawn_args(root_leaf, opts)
			local pane
			tab, pane = window:spawn_tab(cmd)
			tab_opts.pane = pane
			tab_opts.root_notice = notice
		end
		first_tab = first_tab or tab

		if i == 1 and opts.close_open_tabs then
			close_all_other_tabs(window, tab)
		end

		local ok, err = tab_state_mod.restore_tab(tab, tab_state, tab_opts)
		if not ok then
			error(err, 0)
		end
		if tab_state.is_active then
			active_tab = tab
		end
	end

	(active_tab or first_tab):activate()
	return true
end

---restore window state
---@param window MuxWindow
---@param window_state window_state
---@param opts? restore_opts
---@return boolean|nil ok
---@return string|nil err
function pub.restore_window(window, window_state, opts)
	local ok, err = pub.validate(window_state)
	if not ok then
		return nil, err
	end
	local o, owner = tab_state_mod.begin_restore(opts)
	wezterm.emit("resurrect.window_state.restore_window.start")
	local success, result = pcall(restore_window_impl, window, window_state, o)
	tab_state_mod.finish_restore(o, owner)
	if not success then
		return nil, tostring(result)
	end
	wezterm.emit("resurrect.window_state.restore_window.finished")
	return true
end

function pub.save_window_action(opts)
	return wezterm.action_callback(function(win, pane)
		local state_manager = require("resurrect.state_manager")
		local mux_win = win:mux_window()

		local function fail(message)
			wezterm.log_error("resurrect: " .. tostring(message))
			wezterm.emit("resurrect.error", tostring(message))
		end

		local function save()
			local state, err = pub.get_window_state(mux_win, opts)
			if not state then
				return fail(err)
			end
			local path, save_err = state_manager.save_state(state)
			if not path then
				return fail(save_err or "window state was not saved")
			end
		end

		if mux_win:get_title() == "" then
			win:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter new window title",
					action = wezterm.action_callback(function(_, _, title)
						if title and title ~= "" then
							mux_win:set_title(title)
							save()
						end
					end),
				}),
				pane
			)
		else
			save()
		end
	end)
end

return pub
