local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local pane_tree_mod = require("resurrect.pane_tree")
local utils = require("resurrect.utils")
local pub = {}

-- ---------------------------------------------------------------------------
-- Restore context shared by tab/window/workspace/session restores
-- ---------------------------------------------------------------------------

---Prepares options for a restore. The caller's table is never modified: a shallow copy
---gains `warn(message)`, a per-restore `cwd_cache` and the internal `restore_context`.
---Nested restores (workspace -> window -> tab) reuse the outermost context so that
---warnings are summarized exactly once through `opts.on_warning(message)`.
---@param opts? table
---@return table opts
---@return boolean owner  true when the caller must call finish_restore
function pub.begin_restore(opts)
	opts = opts or {}
	if opts.restore_context then
		local copy = {}
		for k, v in pairs(opts) do
			copy[k] = v
		end
		return copy, false
	end
	local ctx = { warnings = {}, seen = {}, cwd_cache = {} }
	local copy = {}
	for k, v in pairs(opts) do
		copy[k] = v
	end
	copy.restore_context = ctx
	copy.cwd_cache = ctx.cwd_cache
	copy.warn = function(message)
		if not ctx.seen[message] then
			ctx.seen[message] = true
			ctx.warnings[#ctx.warnings + 1] = message
		end
	end
	return copy, true
end

---Reports collected warnings once, if this caller owns the context.
---@param opts table  the table returned by begin_restore
---@param owner boolean
function pub.finish_restore(opts, owner)
	if not owner then
		return
	end
	local warnings = opts.restore_context.warnings
	if #warnings > 0 and opts.on_warning then
		local ok, err = pcall(opts.on_warning, table.concat(warnings, "\n"))
		if not ok then
			wezterm.log_error("resurrect on_warning failed: " .. tostring(err))
		end
	end
end

---Spawn command (and optional local notice) for a leaf, from opts.spawn_pane or the default.
---@param leaf pane_leaf
---@param opts table
---@return table cmd
---@return string|nil notice
function pub.spawn_args(leaf, opts)
	local fn = opts.spawn_pane or pane_tree_mod.default_spawn_pane
	local cmd, notice = fn(leaf, opts)
	if type(cmd) ~= "table" then
		error("spawn_pane must return a spawn command table")
	end
	local copy = {}
	for k, v in pairs(cmd) do
		copy[k] = v
	end
	return copy, notice
end

-- ---------------------------------------------------------------------------
-- Capture
-- ---------------------------------------------------------------------------

---Validates a tab state before anything is spawned.
---@param tab_state any
---@return boolean|nil ok
---@return string|nil err
function pub.validate(tab_state)
	if type(tab_state) ~= "table" then
		return nil, "tab state is not a table"
	end
	if tab_state.title ~= nil and type(tab_state.title) ~= "string" then
		return nil, "tab title must be a string"
	end
	if tab_state.is_active ~= nil and type(tab_state.is_active) ~= "boolean" then
		return nil, "tab is_active must be a boolean"
	end
	if tab_state.is_zoomed ~= nil and type(tab_state.is_zoomed) ~= "boolean" then
		return nil, "tab is_zoomed must be a boolean"
	end
	if type(tab_state.pane_tree) ~= "table" then
		return nil, "tab has no pane tree"
	end
	local ok, err = pane_tree_mod.validate(tab_state.pane_tree)
	if not ok then
		return nil, err
	end
	local zoomed = false
	for _, leaf in ipairs(pane_tree_mod.leaves(tab_state.pane_tree)) do
		zoomed = zoomed or leaf.is_zoomed == true
	end
	if (tab_state.is_zoomed == true) ~= zoomed then
		return nil, "tab zoom flag does not match its panes"
	end
	return true
end

---Creates and returns the state of the tab, or nil and an error.
---@param tab MuxTab
---@param opts? pane_capture_opts
---@return tab_state|nil
---@return string|nil err
function pub.get_tab_state(tab, opts)
	local ok, state, err = pcall(function()
		local panes = tab:panes_with_info()
		local tree, tree_err = pane_tree_mod.create_pane_tree(panes, opts)
		if not tree then
			return nil, tree_err
		end
		local zoomed = false
		for _, leaf in ipairs(pane_tree_mod.leaves(tree)) do
			zoomed = zoomed or leaf.is_zoomed
		end
		return { title = tab:get_title(), is_zoomed = zoomed, pane_tree = tree }
	end)
	if not ok then
		return nil, "tab capture failed: " .. tostring(state)
	end
	if not state then
		return nil, err
	end
	return state
end

-- ---------------------------------------------------------------------------
-- Restore
-- ---------------------------------------------------------------------------

---Force closes all other panes in the tab but one
---@param tab MuxTab
---@param pane_to_keep Pane
local function close_all_other_panes(tab, pane_to_keep)
	for _, pane in ipairs(tab:panes()) do
		if pane:pane_id() ~= pane_to_keep:pane_id() then
			pane:activate()
			tab:window():gui_window():perform_action(wezterm.action.CloseCurrentPane({ confirm = false }), pane)
		end
	end
end

local function round(x)
	return math.floor(x + 0.5)
end

---Splits the live `pane` so it ends up holding `node`, recursively.
---Returns true or raises an error naming the problem.
local function build_node(node, pane, live, notices, opts)
	if node.kind == "pane" then
		live[node] = pane
		return
	end

	local first_cols, first_rows = pane_tree_mod.min_size(node.first)
	local second_cols, second_rows = pane_tree_mod.min_size(node.second)
	local dims = pane:get_dimensions()
	local dim, first_min, second_min
	if node.direction == "Right" then
		dim, first_min, second_min = dims.cols, first_cols, second_cols
	else
		dim, first_min, second_min = dims.viewport_rows, first_rows, second_rows
	end
	if dim < first_min + 1 + second_min then
		error(
			string.format(
				"pane area too small to restore the remaining %s split (%d cells available, %d needed)",
				node.direction == "Right" and "horizontal" or "vertical",
				dim,
				first_min + 1 + second_min
			)
		)
	end

	local size = round((dim - 1) * node.second_extent / (node.first_extent + node.second_extent))
	size = math.max(second_min, math.min(size, dim - 1 - first_min))

	local second_leaf = pane_tree_mod.first_leaf(node.second)
	local cmd, notice = pub.spawn_args(second_leaf, opts)
	cmd.direction = node.direction
	cmd.size = size
	local new_pane = pane:split(cmd)
	notices[second_leaf] = notice

	build_node(node.first, pane, live, notices, opts)
	build_node(node.second, new_pane, live, notices, opts)
end

---@param tab MuxTab
---@param tab_state tab_state
---@param opts table  prepared by begin_restore
---@return true
local function restore_tab_impl(tab, tab_state, opts)
	local tree = tab_state.pane_tree
	local root_leaf = pane_tree_mod.first_leaf(tree)
	local notices = { [root_leaf] = opts.root_notice }
	local live = {}

	-- splitting a zoomed tab is not possible; zoom is reapplied at the end
	pcall(tab.set_zoomed, tab, false)

	local root_pane = opts.pane
	if not root_pane then
		local cmd, notice = pub.spawn_args(root_leaf, opts)
		root_pane = tab:active_pane():split(cmd)
		notices[root_leaf] = notice
	end

	if opts.close_open_panes then
		close_all_other_panes(tab, root_pane)
	end

	if tab_state.title and tab_state.title ~= "" then
		tab:set_title(tab_state.title)
	end

	local min_cols, min_rows = pane_tree_mod.min_size(tree)
	local dims = root_pane:get_dimensions()
	if dims.cols < min_cols or dims.viewport_rows < min_rows then
		error(
			string.format(
				"tab area %dx%d is too small for the saved layout (needs at least %dx%d)",
				dims.cols,
				dims.viewport_rows,
				min_cols,
				min_rows
			)
		)
	end

	build_node(tree, root_pane, live, notices, opts)

	local leaves = pane_tree_mod.leaves(tree)
	local active_leaf, zoom_leaf
	for _, leaf in ipairs(leaves) do
		if leaf.is_active then
			active_leaf = leaf
		end
		if leaf.is_zoomed then
			zoom_leaf = leaf
		end
	end
	active_leaf = active_leaf or zoom_leaf or leaves[1]

	do
		local on_pane_restore = opts.on_pane_restore or pub.default_on_pane_restore
		for _, leaf in ipairs(leaves) do
			local copy = utils.deepcopy(leaf)
			copy.pane = live[leaf]
			copy.restore_notice = notices[leaf]
			local ok, err = pcall(on_pane_restore, copy)
			if not ok then
				opts.warn("Restoring pane contents failed: " .. tostring(err))
			end
		end
	end

	if zoom_leaf then
		live[zoom_leaf]:activate()
		tab:set_zoomed(true)
		if active_leaf ~= zoom_leaf then
			live[active_leaf]:activate()
		end
	else
		live[active_leaf]:activate()
	end
	return true
end

---restore a tab
---@param tab MuxTab
---@param tab_state tab_state
---@param opts? restore_opts
---@return boolean|nil ok
---@return string|nil err
function pub.restore_tab(tab, tab_state, opts)
	local ok, err = pub.validate(tab_state)
	if not ok then
		return nil, err
	end
	local o, owner = pub.begin_restore(opts)
	wezterm.emit("resurrect.tab_state.restore_tab.start")
	local success, result = pcall(restore_tab_impl, tab, tab_state, o)
	pub.finish_restore(o, owner)
	if not success then
		return nil, "tab restore failed: " .. tostring(result)
	end
	wezterm.emit("resurrect.tab_state.restore_tab.finished")
	return true
end

function pub.save_tab_action(opts)
	return wezterm.action_callback(function(win, pane)
		local state_manager = require("resurrect.state_manager")
		local tab = pane:tab()

		local function fail(message)
			wezterm.log_error("resurrect: " .. tostring(message))
			wezterm.emit("resurrect.error", tostring(message))
		end

		local function save()
			local state, err = pub.get_tab_state(tab, opts)
			if not state then
				return fail(err)
			end
			local path, save_err = state_manager.save_state(state)
			if not path then
				return fail(save_err or "tab state was not saved")
			end
		end

		if tab:get_title() == "" then
			win:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter new tab title",
					action = wezterm.action_callback(function(_, _, title)
						if title and title ~= "" then
							tab:set_title(title)
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

--- Restores plain local history into a restored pane. It never runs a command, replays
--- program arguments, or writes anything to a foreign domain.
---
--- A leaf carrying `restore_notice` (remote domain placeholder) shows only that notice.
---@param leaf pane_leaf  with a transient `pane`
function pub.default_on_pane_restore(leaf)
	local pane = leaf.pane
	if not pane then
		return
	end

	if leaf.restore_notice then
		pane:inject_output("[" .. pub.sanitize_notice(leaf.restore_notice) .. "]\r\n")
		return
	end

	local domain = leaf.domain
	if domain ~= nil and domain ~= "" and domain ~= "local" then
		return
	end

	if leaf.alt_screen_active then
		pane:inject_output("[A full-screen program was running here in the previous session; it was not restarted]\r\n")
	elseif type(leaf.text) == "string" and leaf.text ~= "" then
		local text = pane_tree_mod.limit_lines(pane_tree_mod.sanitize_text(leaf.text), pane_tree_mod.max_nlines)
		text = text:gsub("%s+$", "")
		if text ~= "" then
			pane:inject_output("[Previous session history]\r\n" .. text .. "\r\n[End of previous session history]\r\n")
		end
	end
end

---@param notice string
---@return string
function pub.sanitize_notice(notice)
	return (pane_tree_mod.sanitize_text(notice):gsub("[\r\n]+", " "))
end

return pub
