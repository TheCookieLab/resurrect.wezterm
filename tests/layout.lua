-- Behavioral tests for pane trees, tab/window/workspace restoration and session capture.
-- Runs inside WezTerm's embedded Lua. WezTerm has no mux here, so a small fake mux with
-- real split arithmetic (divider consumes one cell, split size is the NEW pane's cells)
-- provides deterministic geometry.
local wezterm = require("wezterm")
local utils = require("resurrect.utils")
local pane_tree = require("resurrect.pane_tree")
local tab_state = require("resurrect.tab_state")
local window_state = require("resurrect.window_state")
local workspace_state = require("resurrect.workspace_state")
local session_state = require("resurrect.session_state")
local state_manager = require("resurrect.state_manager")

local DIR = os.getenv("RESURRECT_TEST_DIR")

-- ---------------------------------------------------------------------------
-- Assertion helpers
-- ---------------------------------------------------------------------------

local function check(cond, msg)
	if not cond then
		error(msg or "assertion failed", 2)
	end
end

local function eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg or "values differ", tostring(expected), tostring(actual)), 2)
	end
end

local function serialize(v, seen)
	if type(v) ~= "table" then
		return type(v) == "string" and string.format("%q", v) or tostring(v)
	end
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = tostring(k) .. "=" .. serialize(v[k])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function deep_eq(a, b, msg)
	local sa, sb = serialize(a), serialize(b)
	if sa ~= sb then
		error((msg or "tables differ") .. "\n  " .. sa .. "\n  " .. sb, 2)
	end
end

local function expect_error(fn, pattern, msg)
	local ok, err = pcall(fn)
	check(not ok, (msg or "expected an error") .. ": call succeeded")
	check(tostring(err):find(pattern, 1, true), (msg or "error") .. ": unexpected message " .. tostring(err))
end

local function contains(s, needle, msg)
	check(type(s) == "string" and s:find(needle, 1, true), (msg or "text") .. ": missing '" .. needle .. "' in " .. tostring(s))
end

-- ---------------------------------------------------------------------------
-- Fake mux
-- ---------------------------------------------------------------------------

local W = {}

local function reset_world()
	W = {
		next_id = 1,
		windows = {},
		active_workspace = "default",
		log = {},
		domains = {},
		set_inner_size_calls = 0,
		gui_requests = {},
	}
	W.mux = {
		all_windows = function()
			local out = {}
			for i, w in ipairs(W.windows) do
				out[i] = w
			end
			return out
		end,
		get_active_workspace = function()
			return W.active_workspace
		end,
		set_active_workspace = function(name)
			W.active_workspace = name
			W.log[#W.log + 1] = "set_active_workspace:" .. name
		end,
		get_domain = function(name)
			local d = W.domains[name]
			if not d then
				error("no such domain " .. tostring(name))
			end
			return { is_spawnable = function() return d.spawnable end }
		end,
		spawn_window = function(cmd)
			W.log[#W.log + 1] = "spawn_window"
			W.spawned = W.spawned or {}
			W.spawned[#W.spawned + 1] = cmd
			local win = W.new_window(W.next_window_id and W.next_window_id() or nil, cmd.workspace or W.active_workspace)
			local tab, pane = win:spawn_tab({ cwd = cmd.cwd, domain = cmd.domain, width = cmd.width, height = cmd.height })
			return tab, pane, win
		end,
	}
	wezterm.mux = W.mux
end

local function new_id()
	W.next_id = W.next_id + 1
	return W.next_id
end

local function rect_of(p)
	return p.rect
end

local function new_pane(tab, rect, props)
	local pane = { id = new_id(), owner = tab, rect = rect, props = props or {}, reads = { cwd = 0, text = 0, process = 0 }, injected = {} }
	function pane:pane_id() return self.id end
	function pane:get_domain_name()
		if self.props.domain_error then error("domain vanished") end
		return self.props.domain or "local"
	end
	function pane:get_current_working_dir()
		self.reads.cwd = self.reads.cwd + 1
		if not self.props.cwd then return nil end
		return { host = self.props.host or "", file_path = self.props.cwd }
	end
	function pane:is_alt_screen_active() return self.props.alt == true end
	function pane:get_lines_as_text(n)
		self.reads.text = self.reads.text + 1
		return self.props.text
	end
	function pane:get_dimensions()
		return { cols = self.rect.width, viewport_rows = self.rect.height, scrollback_rows = self.props.scrollback or 10 }
	end
	function pane:get_foreground_process_info()
		self.reads.process = self.reads.process + 1
		return self.props.process
	end
	function pane:inject_output(s) self.injected[#self.injected + 1] = s end
	function pane:activate()
		self.owner.active = self
		self.owner.log[#self.owner.log + 1] = "activate:" .. tostring(self.props.payload)
	end
	function pane:tab() return self.owner end
	function pane:split(cmd)
		local tab = self.owner
		if tab.zoomed then error("cannot split a zoomed tab") end
		local size = cmd.size
		if type(size) ~= "number" or size < 1 or size ~= math.floor(size) then
			error("split size must be a whole number of cells, got " .. tostring(size))
		end
		local r = self.rect
		local new_rect
		if cmd.direction == "Right" then
			local remain = r.width - size - 1
			if remain < 1 then error("no room for a horizontal split") end
			new_rect = { left = r.left + remain + 1, top = r.top, width = size, height = r.height }
			r.width = remain
		elseif cmd.direction == "Bottom" then
			local remain = r.height - size - 1
			if remain < 1 then error("no room for a vertical split") end
			new_rect = { left = r.left, top = r.top + remain + 1, width = r.width, height = size }
			r.height = remain
		else
			error("bad direction")
		end
		tab.splits[#tab.splits + 1] = { direction = cmd.direction, size = size }
		local props = { payload = cmd.cwd, cwd = cmd.cwd, spawn = cmd }
		local p = new_pane(tab, new_rect, props)
		tab.panes_[#tab.panes_ + 1] = p
		return p
	end
	return pane
end

local function new_tab(window, rect_list, opts)
	opts = opts or {}
	local tab = { id = new_id(), owner = window, panes_ = {}, splits = {}, log = {}, title = opts.title or "" }
	function tab:panes_with_info()
		local out = {}
		for i, p in ipairs(self.panes_) do
			out[i] = {
				index = i - 1,
				is_active = self.active == p,
				is_zoomed = self.zoomed == p,
				left = p.rect.left,
				top = p.rect.top,
				width = p.rect.width,
				height = p.rect.height,
				pane = p,
			}
		end
		return out
	end
	function tab:panes() return self.panes_ end
	function tab:get_size()
		local right, bottom = 0, 0
		for _, p in ipairs(self.panes_) do
			right = math.max(right, p.rect.left + p.rect.width)
			bottom = math.max(bottom, p.rect.top + p.rect.height)
		end
		return { cols = right, rows = bottom, pixel_width = right * 8, pixel_height = bottom * 16, dpi = 96 }
	end
	function tab:get_title() return self.title end
	function tab:set_title(t) self.title = t end
	function tab:set_zoomed(on)
		self.log[#self.log + 1] = "zoom:" .. tostring(on)
		self.zoomed = on and self.active or nil
	end
	function tab:active_pane() return self.active end
	function tab:tab_id() return self.id end
	function tab:window() return self.owner end
	function tab:activate()
		self.owner.active = self
	end
	for _, r in ipairs(rect_list) do
		local p = new_pane(tab, { left = r.left, top = r.top, width = r.width, height = r.height }, r.props or { payload = r.payload, cwd = r.payload })
		tab.panes_[#tab.panes_ + 1] = p
		if r.active then tab.active = p end
		if r.zoomed then tab.zoomed = p end
	end
	tab.active = tab.active or tab.panes_[1]
	return tab
end

local function new_window(id, workspace)
	local win = { id = id or new_id(), workspace = workspace, tabs_ = {}, title = "", set_workspace_calls = {} }
	W.windows[#W.windows + 1] = win
	function win:window_id() return self.id end
	function win:get_title() return self.title end
	function win:set_title(t) self.title = t end
	function win:get_workspace() return self.workspace end
	function win:set_workspace(name)
		self.workspace = name
		self.set_workspace_calls[#self.set_workspace_calls + 1] = name
	end
	function win:tabs() return self.tabs_ end
	function win:tabs_with_info()
		local out = {}
		for i, t in ipairs(self.tabs_) do
			out[i] = { index = i - 1, is_active = self.active == t, tab = t }
		end
		return out
	end
	function win:active_tab() return self.active end
	function win:active_pane() return self.active:active_pane() end
	function win:spawn_tab(cmd)
		local size = cmd.width and { cols = cmd.width, rows = cmd.height } or self.size or { cols = 81, rows = 25 }
		self.size = size
		local tab = new_tab(self, {
			{ payload = cmd.cwd, left = 0, top = 0, width = size.cols, height = size.rows, props = { payload = cmd.cwd, cwd = cmd.cwd, spawn = cmd } },
		})
		self.tabs_[#self.tabs_ + 1] = tab
		self.active = self.active or tab
		return tab, tab.active, self
	end
	function win:gui_window()
		W.gui_requests[#W.gui_requests + 1] = self.id
		return {
			focus = function() W.log[#W.log + 1] = "focus:" .. tostring(self.id) end,
			set_inner_size = function() W.set_inner_size_calls = W.set_inner_size_calls + 1 end,
		}
	end
	return win
end
W.new_window = nil

local function make_window(id, workspace, tabs)
	local win = new_window(id, workspace)
	for _, spec in ipairs(tabs) do
		local tab = new_tab(win, spec.rects, { title = spec.title })
		win.tabs_[#win.tabs_ + 1] = tab
		if spec.active then win.active = tab end
	end
	win.active = win.active or win.tabs_[1]
	return win
end


local function init_world()
	reset_world()
	W.new_window = function(id, workspace)
		return new_window(id, workspace)
	end
end


-- ---------------------------------------------------------------------------
-- Layout fixtures: {payload, left, top, width, height}; the divider is one cell.
-- ---------------------------------------------------------------------------

local function R(payload, left, top, width, height, extra)
	local r = { payload = payload, left = left, top = top, width = width, height = height }
	for k, v in pairs(extra or {}) do
		r[k] = v
	end
	return r
end

local layouts = {
	["2x2"] = function()
		return { R("A", 0, 0, 40, 12), R("B", 41, 0, 40, 12), R("C", 0, 13, 40, 12), R("D", 41, 13, 40, 12) }
	end,
	["T left"] = function()
		return { R("A", 0, 0, 40, 25), R("B", 41, 0, 40, 12), R("C", 41, 13, 40, 12) }
	end,
	["T top"] = function()
		return { R("A", 0, 0, 81, 12), R("B", 0, 13, 40, 12), R("C", 41, 13, 40, 12) }
	end,
	["asymmetric"] = function()
		return { R("A", 0, 0, 30, 25), R("B", 31, 0, 50, 8), R("C", 31, 9, 20, 16), R("D", 52, 9, 29, 16) }
	end,
	["nested 3x3"] = function()
		local out = {}
		local xs, ys = { 0, 27, 54 }, { 0, 8, 16 }
		for r = 1, 3 do
			for c = 1, 3 do
				out[#out + 1] = R("P" .. r .. c, xs[c], ys[r], 26, 7)
			end
		end
		return out
	end,
	["single"] = function()
		return { R("A", 0, 0, 80, 24) }
	end,
}

local function rect_key(r)
	return string.format("%d,%d,%d,%d", r.left, r.top, r.width, r.height)
end

local function geometry_by_payload(tab)
	local out = {}
	for _, info in ipairs(tab:panes_with_info()) do
		out[info.pane.props.payload] = rect_key(info)
	end
	return out
end

local function restore_opts(extra)
	local opts = {
		spawn_pane = function(leaf)
			return { cwd = leaf.cwd }
		end,
		on_pane_restore = function(leaf)
			leaf.pane.props.payload = leaf.cwd
			leaf.pane.props.cwd = leaf.cwd
		end,
	}
	for k, v in pairs(extra or {}) do
		opts[k] = v
	end
	return opts
end

-- A fresh single-pane tab of the given size to restore into.
local function blank_tab(cols, rows, workspace)
	local win = new_window(nil, workspace or "default")
	local tab, pane = win:spawn_tab({ cols = cols, width = cols, height = rows, cwd = "root" })
	return tab, pane, win
end

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

-- ---------------------------------------------------------------------------
-- Pane tree capture and geometry round-trip
-- ---------------------------------------------------------------------------

for name, make in pairs(layouts) do
	test("layout " .. name .. " is captured once per pane and restores exactly", function()
		init_world()
		local rects = make()
		local win = make_window(nil, "default", { { rects = rects } })
		local tab = win.tabs_[1]
		local before = serialize(geometry_by_payload(tab))
		local state, err = tab_state.get_tab_state(tab)
		check(state, err)
		eq(serialize(geometry_by_payload(tab)), before, "capture must not mutate the observation")
		local ok, verr = pane_tree.validate(state.pane_tree)
		check(ok, verr)

		local leaves = pane_tree.leaves(state.pane_tree)
		eq(#leaves, #rects, "leaf count")
		local seen = {}
		for _, leaf in ipairs(leaves) do
			check(not seen[leaf.cwd], "payload " .. leaf.cwd .. " owned twice")
			seen[leaf.cwd] = true
		end
		for _, r in ipairs(rects) do
			check(seen[r.payload], "payload " .. r.payload .. " missing")
		end

		local snapshot = serialize(state)
		local size = tab:get_size()
		for round = 1, 2 do
			local new_tab_, root = blank_tab(size.cols, size.rows)
			local restored, rerr = tab_state.restore_tab(new_tab_, state, restore_opts({ pane = root }))
			check(restored, rerr)
			eq(#new_tab_:panes_with_info(), #rects, "restored pane count")
			local expected = {}
			for _, r in ipairs(rects) do
				expected[r.payload] = rect_key(r)
			end
			deep_eq(geometry_by_payload(new_tab_), expected, "restored geometry round " .. round)
			eq(serialize(state), snapshot, "restoring must not mutate the saved state")
		end
	end)
end

test("a pinwheel layout has no slicing tree and aborts capture", function()
	init_world()
	local win = make_window(nil, "default", {
		{ rects = { R("A", 0, 0, 50, 10), R("B", 51, 0, 30, 16), R("C", 31, 17, 50, 8), R("D", 0, 11, 30, 14) } },
	})
	local state, err = tab_state.get_tab_state(win.tabs_[1])
	check(state == nil and err, "pinwheel must not produce a state")
end)

test("overlaps, duplicates and impossible geometry abort capture", function()
	init_world()
	local overlapping = make_window(nil, "default", { { rects = { R("A", 0, 0, 50, 10), R("B", 40, 0, 40, 10) } } })
	check(select(1, tab_state.get_tab_state(overlapping.tabs_[1])) == nil, "overlap must abort")
	local empty_tab = make_window(nil, "default", { { rects = { R("A", 0, 0, 10, 10) } } }).tabs_[1]
	empty_tab.panes_ = {}
	local state, err = tab_state.get_tab_state(empty_tab)
	check(state == nil and err, "a tab without panes is not a valid empty capture")
end)

test("scaling a saved layout keeps proportions and one divider cell", function()
	init_world()
	local win = make_window(nil, "default", { { rects = layouts["2x2"]() } })
	local state = assert(tab_state.get_tab_state(win.tabs_[1]))
	local tab, root = blank_tab(41, 25)
	check(tab_state.restore_tab(tab, state, restore_opts({ pane = root })))
	local geo = {}
	for _, info in ipairs(tab:panes_with_info()) do
		geo[info.pane.props.payload] = info
	end
	eq(geo.A.width + 1 + geo.B.width, 41, "row width")
	check(math.abs(geo.A.width - 20) <= 1, "A about half the width, got " .. geo.A.width)
	eq(geo.A.height + 1 + geo.C.height, 25, "column height")
end)

test("a too-small reused tab is rejected before any split", function()
	init_world()
	local win = make_window(nil, "default", { { rects = layouts["nested 3x3"]() } })
	local state = assert(tab_state.get_tab_state(win.tabs_[1]))
	local tab, root = blank_tab(4, 4)
	local ok, err = tab_state.restore_tab(tab, state, restore_opts({ pane = root }))
	check(ok == nil and err, "restore into a 4x4 tab must fail")
	eq(#tab.splits, 0, "no splits may be attempted")
end)

test("a malformed tree is rejected before spawning anything", function()
	init_world()
	local tab, root = blank_tab(80, 24)
	local bad = {
		title = "x",
		is_zoomed = false,
		pane_tree = {
			kind = "split",
			direction = "Right",
			first_extent = 10,
			second_extent = 10,
			first = { kind = "pane", left = 0, top = 0, width = 10, height = 5 },
			second = { kind = "pane", left = 3, top = 0, width = 10, height = 5 },
		},
	}
	local ok, err = tab_state.restore_tab(tab, bad, restore_opts({ pane = root }))
	check(ok == nil and err, "invalid geometry must be refused")
	eq(#tab.splits, 0, "no splits")
	local unknown = tab_state.restore_tab(tab, { pane_tree = { kind = "triangle" } }, restore_opts({ pane = root }))
	check(unknown == nil, "unknown node kind")
end)

-- ---------------------------------------------------------------------------
-- Active and zoomed panes
-- ---------------------------------------------------------------------------

test("active and zoomed panes are independent and restored in a legal order", function()
	init_world()
	local rects = layouts["2x2"]()
	rects[2].zoomed = true -- B
	rects[3].active = true -- C
	local win = make_window(nil, "default", { { rects = rects } })
	local source = win.tabs_[1]
	local state = assert(tab_state.get_tab_state(source))
	eq(state.is_zoomed, true, "tab zoom flag")
	local flags = {}
	for _, leaf in ipairs(pane_tree.leaves(state.pane_tree)) do
		flags[leaf.cwd] = (leaf.is_active and "a" or "") .. (leaf.is_zoomed and "z" or "")
	end
	deep_eq(flags, { A = "", B = "z", C = "a", D = "" }, "saved flags")

	local size = source:get_size()
	local tab, root = blank_tab(size.cols, size.rows)
	check(tab_state.restore_tab(tab, state, restore_opts({ pane = root })))
	eq(tab.zoomed.props.payload, "B", "zoomed pane")
	eq(tab.active.props.payload, "C", "active pane")
	eq(tab.log[#tab.log - 2], "activate:B", "zoom target activated first")
	eq(tab.log[#tab.log - 1], "zoom:true", "then zoomed")
	eq(tab.log[#tab.log], "activate:C", "then the active pane")

	-- Capturing the restored (still zoomed) tab validates again and is identical.
	local again, err = tab_state.get_tab_state(tab)
	check(again, err)
	local function geometry(s)
		local out = {}
		for _, leaf in ipairs(pane_tree.leaves(s.pane_tree)) do
			out[leaf.cwd] = rect_key(leaf) .. tostring(leaf.is_active) .. tostring(leaf.is_zoomed)
		end
		return out
	end
	deep_eq(geometry(again), geometry(state), "second capture")
end)

test("a tab without an active flag activates the zoomed pane, then the first", function()
	init_world()
	local rects = layouts["T left"]()
	local win = make_window(nil, "default", { { rects = rects } })
	local state = assert(tab_state.get_tab_state(win.tabs_[1]))
	for _, leaf in ipairs(pane_tree.leaves(state.pane_tree)) do
		leaf.is_active = false
	end
	local tab, root = blank_tab(81, 25)
	check(tab_state.restore_tab(tab, state, restore_opts({ pane = root })))
	eq(tab.active.props.payload, "A", "first leaf")
end)

test("two active or two zoomed leaves are invalid", function()
	init_world()
	local rects = layouts["2x2"]()
	rects[1].active = true
	local win = make_window(nil, "default", { { rects = rects } })
	local state = assert(tab_state.get_tab_state(win.tabs_[1]))
	local leaves = pane_tree.leaves(state.pane_tree)
	leaves[2].is_active = true
	check(not pane_tree.validate(state.pane_tree), "two active leaves")
	leaves[2].is_active = false
	leaves[1].is_zoomed, leaves[2].is_zoomed = true, true
	check(not pane_tree.validate(state.pane_tree), "two zoomed leaves")
end)

-- ---------------------------------------------------------------------------
-- Capture contracts
-- ---------------------------------------------------------------------------

test("missing process info never aborts capture and is never queried by default", function()
	init_world()
	local win = make_window(nil, "default", {
		{ rects = { R("A", 0, 0, 10, 5, { props = { payload = "A", cwd = "A", process = nil, text = "hi" } }) } },
	})
	local pane = win.tabs_[1].panes_[1]
	local state = assert(tab_state.get_tab_state(win.tabs_[1]))
	eq(pane.reads.process, 0, "process queried without capture_process")
	eq(pane_tree.first_leaf(state.pane_tree).process, nil, "process stored without capture_process")

	local with = assert(tab_state.get_tab_state(win.tabs_[1], { capture_process = true }))
	eq(pane.reads.process, 1, "process queried once")
	eq(pane_tree.first_leaf(with.pane_tree).process, nil, "nil process info stays nil")

	pane.props.process = { name = "vim", argv = { "vim", "a b" }, cwd = "/x", executable = "/usr/bin/vim", pid = 7, ppid = 1, children = {} }
	local full = assert(tab_state.get_tab_state(win.tabs_[1], { capture_process = true }))
	local p = pane_tree.first_leaf(full.pane_tree).process
	deep_eq(p, { name = "vim", argv = { "vim", "a b" }, cwd = "/x", executable = "/usr/bin/vim" }, "only available fields copied")

	pane.props.process = { argv = { "x" } }
	local nameless = assert(tab_state.get_tab_state(win.tabs_[1], { capture_process = true }))
	deep_eq(pane_tree.first_leaf(nameless.pane_tree).process, { argv = { "x" } }, "missing name is valid")
end)

test("alt-screen panes keep no text and restore a fresh shell with a note", function()
	init_world()
	local win = make_window(nil, "default", {
		{ rects = { R("A", 0, 0, 10, 5, { props = { payload = "A", cwd = "A", alt = true, text = "SECRET", process = { name = "vim" } } }) } },
	})
	local state = assert(tab_state.get_tab_state(win.tabs_[1]))
	local leaf = pane_tree.first_leaf(state.pane_tree)
	eq(leaf.alt_screen_active, true, "alt flag")
	eq(leaf.text, nil, "alt text")
	eq(win.tabs_[1].panes_[1].reads.text, 0, "alt-screen buffer must not be read")

	local tab, root = blank_tab(10, 5)
	check(tab_state.restore_tab(tab, state, restore_opts({ pane = root, on_pane_restore = tab_state.default_on_pane_restore })))
	local injected = table.concat(root.injected)
	contains(injected, "was not restarted", "alt note")
	check(not injected:find("vim", 1, true), "no program name replay")
end)

test("the capture hook runs before any read and can suppress cwd, text and process", function()
	init_world()
	local ssh_props = { payload = "S", cwd = "/remote", text = "remote text", process = { name = "ssh" }, host = "" }
	local win = make_window(nil, "default", {
		{ rects = { R("S", 0, 0, 10, 5, { props = ssh_props }), R("L", 11, 0, 10, 5, { props = { payload = "L", cwd = "/local", text = "local text\n" } }) } },
	})
	local ssh_pane, local_pane = win.tabs_[1].panes_[1], win.tabs_[1].panes_[2]
	local hook_saw = {}
	local state = assert(tab_state.get_tab_state(win.tabs_[1], {
		capture_process = true,
		on_pane_capture = function(pane, leaf)
			hook_saw[pane:pane_id()] = pane.reads.cwd + pane.reads.text + pane.reads.process
			if pane == ssh_pane then
				leaf.metadata = { terminal_profile = { kind = "ssh", host = "alias" } }
				return false
			end
		end,
	}))
	eq(hook_saw[ssh_pane.id], 0, "hook ran after reads on the ssh pane")
	eq(hook_saw[local_pane.id], 0, "hook ran after reads on the local pane")
	eq(ssh_pane.reads.cwd + ssh_pane.reads.text + ssh_pane.reads.process, 0, "suppressed pane was read")
	local leaves = pane_tree.leaves(state.pane_tree)
	local ssh_leaf, local_leaf = leaves[1], leaves[2]
	eq(ssh_leaf.cwd, "", "suppressed cwd")
	eq(ssh_leaf.text, nil, "suppressed text")
	eq(ssh_leaf.process, nil, "suppressed process")
	eq(ssh_leaf.metadata.terminal_profile.host, "alias", "metadata")
	eq(local_leaf.cwd, "/local", "local cwd kept")
	eq(local_leaf.text, "local text", "local text kept")
end)

test("non-local text capture is opt-in and still never injected on restore", function()
	init_world()
	W.domains["SSH:box"] = { spawnable = true }
	local make = function()
		return make_window(nil, "default", {
			{ rects = { R("R", 0, 0, 10, 5, { props = { payload = "R", domain = "SSH:box", cwd = "/srv", host = "box", text = "remote history" } }) } },
		})
	end
	local off = assert(tab_state.get_tab_state(make().tabs_[1]))
	eq(pane_tree.first_leaf(off.pane_tree).text, nil, "default must not capture remote text")
	local on = assert(tab_state.get_tab_state(make().tabs_[1], { save_non_local_domains = true }))
	local leaf = pane_tree.first_leaf(on.pane_tree)
	eq(leaf.text, "remote history", "opt-in capture")
	eq(leaf.cwd, "/srv", "non-local cwd is kept verbatim")

	local warnings = {}
	local cmd, notice = pane_tree.default_spawn_pane(leaf, { warn = function(m) warnings[#warnings + 1] = m end })
	eq(cmd.domain, nil, "no domain connection")
	contains(notice, "Remote domain SSH:box is disconnected; use the Domains launcher to attach", "notice")

	local tab, root = blank_tab(10, 5)
	local copy = utils.deepcopy(leaf)
	copy.pane, copy.restore_notice = root, notice
	tab_state.default_on_pane_restore(copy)
	local injected = table.concat(root.injected)
	contains(injected, "disconnected", "notice shown")
	check(not injected:find("remote history", 1, true), "remote history injected")
	copy.restore_notice = nil
	root.injected = {}
	tab_state.default_on_pane_restore(copy)
	eq(#root.injected, 0, "foreign domain gets nothing even without a notice")
end)

test("a foreign-host cwd is dropped for native panes", function()
	init_world()
	local hostname = wezterm.hostname()
	local short = hostname:match("^[^.]+")
	local function capture(host)
		local win = make_window(nil, "default", {
			{ rects = { R("A", 0, 0, 10, 5, { props = { payload = "A", cwd = "/work", host = host } }) } },
		})
		return pane_tree.first_leaf(assert(tab_state.get_tab_state(win.tabs_[1])).pane_tree).cwd
	end
	eq(capture(""), "/work", "empty host")
	eq(capture("localhost"), "/work", "localhost")
	eq(capture(hostname:upper() .. "."), "/work", "case-insensitive FQDN with final dot")
	eq(capture(short), "/work", "short host equals first label")
	eq(capture("definitely-not-this-host.invalid"), "", "foreign host")
end)

test("terminal text is sanitized as UTF-8 and line endings are normalized once", function()
	local input = "a\0b\1c\tT\r\nL\nD\127\u{e9}\u{85}g\u{2014}\u{1F600}\27[31mred"
	eq(pane_tree.sanitize_text(input), "abc\tT\r\nL\r\nD\u{e9}g\u{2014}\u{1F600}[31mred", "sanitized text")
	local twice = pane_tree.sanitize_text(pane_tree.sanitize_text(input))
	eq(twice, pane_tree.sanitize_text(input), "idempotent")
	eq(pane_tree.limit_lines("1\r\n2\r\n3\r\n4", 2), "3\r\n4", "line limit keeps the newest lines")
end)

-- ---------------------------------------------------------------------------
-- Spawn contracts
-- ---------------------------------------------------------------------------

test("default spawn keeps readable folders, drops missing ones and reports once", function()
	init_world()
	local real = DIR .. "/folder with space \u{fc}\u{4e2d}"
	local made, merr = utils.ensure_folder_exists(real)
	check(made, merr)
	local missing1, missing2 = DIR .. "/gone-1", DIR .. "/gone-2"

	local function tab_with(cwds)
		local rects = {}
		for i, cwd in ipairs(cwds) do
			rects[i] = R("P" .. i, (i - 1) * 11, 0, 10, 5, { props = { payload = "P" .. i, cwd = cwd } })
		end
		local win = make_window(nil, "default", { { rects = rects } })
		return assert(tab_state.get_tab_state(win.tabs_[1]))
	end
	local state = tab_with({ real, missing1, missing2, missing1 })

	local warnings = {}
	local tab, root = blank_tab(44, 5)
	local ok, err = tab_state.restore_tab(tab, state, {
		pane = root,
		on_warning = function(m) warnings[#warnings + 1] = m end,
	})
	check(ok, err)
	eq(#warnings, 1, "one summary for all missing folders")
	contains(warnings[1], "gone-1", "first missing folder named")
	contains(warnings[1], "gone-2", "second missing folder named")
	local cwds = {}
	for _, p in ipairs(tab.panes_) do
		if p ~= root and p.props.spawn then cwds[#cwds + 1] = tostring(p.props.spawn.cwd) end
	end
	check(#cwds == 3, "three split panes, got " .. #cwds .. " of " .. #tab.panes_ .. " panes")
	deep_eq(cwds, { "nil", "nil", "nil" }, "missing folders omitted from split spawns")
	local kept = pane_tree.default_spawn_pane({ domain = "local", cwd = real }, {})
	eq(kept.cwd, real, "readable folder kept")
end)

test("only local and configured WSL domains are ever targeted", function()
	init_world()
	W.domains["WSL:Ubuntu"] = { spawnable = true }
	local cmd = pane_tree.default_spawn_pane({ domain = "WSL:Ubuntu", cwd = "/mnt/c/Users/x" }, {})
	eq(cmd.domain.DomainName, "WSL:Ubuntu", "wsl domain")
	eq(cmd.cwd, "/mnt/c/Users/x", "wsl path is not translated")
	local missing, notice = pane_tree.default_spawn_pane({ domain = "WSL:Gone", cwd = "/home/x" }, {})
	eq(missing.domain, nil, "missing wsl domain")
	eq(missing.cwd, nil, "missing wsl cwd")
	check(notice, "labelled")
	for _, name in ipairs({ "SSH:box", "SSHMUX:box", "unix", "TLS:x" }) do
		local c, n = pane_tree.default_spawn_pane({ domain = name, cwd = "/x" }, {})
		eq(c.domain, nil, name .. " must not connect")
		eq(c.cwd, nil, name .. " cwd")
		check(n, name .. " notice")
	end
end)

test("restore uses spawn_pane for every pane and never replays saved commands", function()
	init_world()
	local rects = layouts["2x2"]()
	for _, r in ipairs(rects) do
		r.props = { payload = r.payload, cwd = r.payload, process = { name = "rm", argv = { "rm", "-rf", "/" } }, text = "output of " .. r.payload }
	end
	local win = make_window(nil, "default", { { rects = rects } })
	local state = assert(tab_state.get_tab_state(win.tabs_[1], { capture_process = true }))
	local snapshot = serialize(state)
	local calls = {}
	local tab, root = blank_tab(81, 25)
	check(tab_state.restore_tab(tab, state, {
		pane = root,
		spawn_pane = function(leaf)
			calls[#calls + 1] = leaf.cwd
			return { cwd = leaf.cwd }
		end,
	}))
	eq(#calls, 3, "one spawn per split pane")
	for _, p in ipairs(tab.panes_) do
		if p.props.spawn then
			eq(p.props.spawn.args, nil, "args")
			eq(p.props.spawn.set_environment_variables, nil, "env")
		end
	end
	eq(serialize(state), snapshot, "state untouched, including captured argv")
	for _, p in ipairs(tab.panes_) do
		local out = table.concat(p.injected)
		check(not out:find("rm -rf", 1, true), "argv injected")
		contains(out, "Previous session history", "history marker")
	end
end)

-- ---------------------------------------------------------------------------
-- Named save actions
-- ---------------------------------------------------------------------------

local function capture_callbacks()
	local captured = {}
	local original = wezterm.action_callback
	wezterm.action_callback = function(fn)
		captured[#captured + 1] = fn
		return original(fn)
	end
	return captured, function()
		wezterm.action_callback = original
	end
end

local function fake_gui_window(mux_window, performed)
	local gw = { performed = performed }
	function gw:mux_window() return mux_window end
	function gw:perform_action(action, pane) performed[#performed + 1] = action end
	return gw
end

local action_counter = 0

local function action_case(kind, title)
	init_world()
	action_counter = action_counter + 1
	state_manager.change_state_save_dir(DIR .. "/named-" .. action_counter)
	local win = make_window(30, "default", { { title = kind == "tab" and title or "Tab", rects = layouts["T left"]() } })
	if kind == "window" then
		win.title = title
	end
	local tab = win.tabs_[1]
	local performed = {}
	local gui = fake_gui_window(win, performed)
	local factory = kind == "tab" and tab_state.save_tab_action or window_state.save_window_action
	local captured, restore = capture_callbacks()
	local ok, err = pcall(function()
		factory()
		captured[1](gui, tab.panes_[1])
	end)
	restore()
	check(ok, err)
	return { captured = captured, gui = gui, pane = tab.panes_[1], tab = tab, win = win, performed = performed }
end

for _, kind in ipairs({ "tab", "window" }) do
	test(kind .. " save action saves a titled state through state_manager.save_state", function()
		local case = action_case(kind, "Already Titled")
		eq(#case.performed, 0, "no prompt expected")
		local state, err = state_manager.load_state("Already Titled", kind)
		check(state, err)
		eq(state.title, "Already Titled", "title round trip")
		if kind == "tab" then
			eq(#pane_tree.leaves(state.pane_tree), 3, "panes saved")
		else
			eq(#state.tabs, 1, "tabs saved")
			eq(state.workspace, "default", "workspace saved")
		end
	end)

	test(kind .. " save action prompts for an untitled state and saves only when titled", function()
		local case = action_case(kind, "")
		eq(#case.performed, 1, "prompt requested")
		local prompt = case.captured[2]
		check(prompt, "prompt callback created")
		prompt(case.gui, case.pane, nil)
		prompt(case.gui, case.pane, "")
		eq(state_manager.load_state("Named Later", kind), nil, "cancelled prompt must not create state")
		prompt(case.gui, case.pane, "Named Later")
		local state, err = state_manager.load_state("Named Later", kind)
		check(state, err)
		eq(state.title, "Named Later", "prompted title persisted")
		eq((kind == "tab" and case.tab or case.win):get_title(), "Named Later", "live title updated")
	end)
end

-- ---------------------------------------------------------------------------
-- Workspaces
-- ---------------------------------------------------------------------------

local function make_source()
	local four = make_window(4, "alpha", {
		{ title = "one", rects = layouts["2x2"]() },
		{ title = "two", rects = { R("X", 0, 0, 81, 25) }, active = true },
	})
	four.title = "Four"
	local nine = make_window(9, "alpha", { { title = "nine", rects = { R("Y", 0, 0, 60, 20) } } })
	local six = make_window(6, "beta", { { title = "six", rects = { R("Z", 0, 0, 70, 22) } } })
	W.active_workspace = "alpha"
	return four, nine, six
end

local function count_log(prefix)
	local n = 0
	for _, entry in ipairs(W.log) do
		if entry:sub(1, #prefix) == prefix then
			n = n + 1
		end
	end
	return n
end

test("workspace capture keeps only the active workspace in window-ID order", function()
	init_world()
	make_source()
	local ws, err = workspace_state.get_workspace_state()
	check(ws, err)
	eq(ws.workspace, "alpha", "workspace name")
	eq(#ws.window_states, 2, "window count")
	eq(ws.window_states[1].title, "Four", "first window is the lower ID")
	eq(ws.window_states[1].size.cols, 81, "size cols")
	eq(ws.window_states[2].size.rows, 20, "size rows")
	eq(ws.window_states[1].tabs[2].is_active, true, "active tab")
	eq(ws.window_states[1].tabs[1].is_active, false, "inactive tab")
end)

test("restoring a workspace spawns cell-sized windows in the target and selects it once", function()
	init_world()
	make_source()
	local ws = assert(workspace_state.get_workspace_state())
	init_world()
	local other = make_window(50, "default", { { rects = { R("keep", 0, 0, 81, 25) } } })
	local before = serialize(ws)
	local windows, err = workspace_state.restore_workspace(ws, restore_opts({ spawn_in_workspace = true }))
	check(windows, err)
	eq(#windows, 2, "windows restored")
	eq(#W.spawned, 2, "spawn_window calls")
	eq(W.spawned[1].width, 81, "cols")
	eq(W.spawned[1].height, 25, "rows")
	eq(W.spawned[2].width, 60, "cols 2")
	eq(W.spawned[2].workspace, "alpha", "workspace")
	eq(W.set_inner_size_calls, 0, "pixel resizing is not used")
	eq(#W.gui_requests, 0, "no GUI window requested")
	eq(count_log("set_active_workspace:"), 1, "workspace selected once")
	eq(W.active_workspace, "alpha", "active workspace")
	eq(other.workspace, "default", "unrelated window untouched")
	eq(#other.tabs_[1].panes_, 1, "unrelated window panes untouched")
	eq(windows[1]:tabs()[2].title, "two", "tab titles")
	eq(windows[1].active, windows[1].tabs_[2], "active tab restored last")
	eq(windows[1].title, "Four", "window title")
	eq(#windows[1].tabs_[1].panes_, 4, "2x2 restored")
	eq(serialize(ws), before, "saved state untouched")
end)

test("a reused window alone moves into the workspace", function()
	init_world()
	make_source()
	local ws = assert(workspace_state.get_workspace_state())
	init_world()
	local bystander = make_window(50, "default", { { rects = { R("keep", 0, 0, 81, 25) } } })
	local reuse = make_window(60, "default", { { rects = { R("root", 0, 0, 81, 25) } } })
	local windows, err = workspace_state.restore_workspace(
		ws,
		restore_opts({ spawn_in_workspace = true, window = reuse, workspace_name = "alpha2" })
	)
	check(windows, err)
	deep_eq(reuse.set_workspace_calls, { "alpha2" }, "reused window moved once")
	eq(#bystander.set_workspace_calls, 0, "bystander untouched")
	eq(bystander.workspace, "default", "bystander workspace")
	eq(#W.spawned, 1, "the other saved window is spawned")
	eq(W.spawned[1].workspace, "alpha2", "spawned into the target")
	eq(W.active_workspace, "alpha2", "target selected after it exists")
end)

test("without spawn_in_workspace no workspace is renamed or selected", function()
	init_world()
	make_source()
	local ws = assert(workspace_state.get_workspace_state())
	init_world()
	local reuse = make_window(60, "default", { { rects = { R("root", 0, 0, 81, 25) } } })
	local windows, err = workspace_state.restore_workspace(ws, restore_opts({ window = reuse }))
	check(windows, err)
	eq(#reuse.set_workspace_calls, 0, "no rename")
	eq(W.spawned[1].workspace, nil, "spawned in the current workspace")
	eq(count_log("set_active_workspace"), 0, "no workspace switch")
end)

test("invalid workspace states are rejected before spawning", function()
	init_world()
	eq(workspace_state.restore_workspace({ workspace = "a", window_states = {} }, restore_opts()), nil, "empty window list")
	eq(workspace_state.restore_workspace({ workspace = "", window_states = { {} } }, restore_opts()), nil, "empty name")
	eq(workspace_state.restore_workspace(nil, restore_opts()), nil, "nil state")
	eq(W.spawned, nil, "nothing spawned")
end)

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

test("session capture orders windows by ID and identifies the focused window", function()
	init_world()
	make_source()
	local state, err = session_state.capture({ focused_window_id = 9 })
	check(state, err)
	eq(state.format_version, 1, "format version")
	eq(state.active_workspace, "alpha", "active workspace")
	eq(#state.windows, 3, "all workspaces")
	eq(state.windows[1].workspace, "alpha", "window 4")
	eq(state.windows[2].workspace, "beta", "window 6")
	eq(state.windows[3].workspace, "alpha", "window 9")
	eq(state.active_window, 3, "focused window index")
	check(session_state.validate(state))
	deep_eq(session_state.counts(state), { windows = 3, tabs = 4, panes = 7 }, "counts")

	local inactive = assert(session_state.capture({ focused_window_id = 6 }))
	eq(inactive.active_window, nil, "inactive-workspace focus")
	check(session_state.validate(inactive))
end)

test("session validation rejects unusable snapshots", function()
	init_world()
	make_source()
	local good = assert(session_state.capture({ focused_window_id = 9 }))
	local function mutated(fn)
		local copy = wezterm.json_parse(wezterm.json_encode(good))
		fn(copy)
		return session_state.validate(copy)
	end
	check(mutated(function() end), "a JSON round trip stays valid")
	check(not mutated(function(s) s.format_version = 2 end), "future version")
	check(not mutated(function(s) s.format_version = nil end), "missing version")
	check(not mutated(function(s) s.windows = {} end), "no windows")
	check(not mutated(function(s) s.active_window = 2 end), "focus in another workspace")
	check(not mutated(function(s) s.active_window = 99 end), "focus out of range")
	check(not mutated(function(s) s.windows[1].tabs = {} end), "tab-less window")
	check(not mutated(function(s) s.windows[1].tabs[1].pane_tree = nil end), "missing tree")
	check(not mutated(function(s) s.windows[1].workspace = "" end), "empty workspace")
	check(not session_state.validate(nil), "nil")
end)

test("capture refuses empty or racing observations", function()
	init_world()
	local state, err = session_state.capture()
	check(state == nil and err, "no windows")
	new_window(5, "default")
	state, err = session_state.capture()
	check(state == nil and err, "window without tabs")
	W.windows = {}
	make_window(8, "default", { { rects = { R("A", 0, 0, 10, 5, { props = { payload = "A", domain_error = true } }) } } })
	state, err = session_state.capture()
	check(state == nil and err, "pane without a domain")
end)

test("additive recovery renames workspaces, leaves live tabs alone and never mutates the state", function()
	init_world()
	make_source()
	local captured = assert(session_state.capture({ focused_window_id = 9 }))
	local state = wezterm.json_parse(wezterm.json_encode(captured))
	local snapshot = serialize(state)

	init_world()
	local live = make_window(70, "alpha", { { title = "live", rects = { R("keep", 0, 0, 81, 25) } } })
	local names = { alpha = "alpha (recovered 2026-10-03 120000)", beta = "beta (recovered 2026-10-03 120000)" }
	local windows, err = session_state.restore(state, restore_opts({ workspace_names = names }))
	check(windows, err)
	eq(#windows, 3, "windows restored")
	eq(W.spawned[1].workspace, names.alpha, "alpha renamed")
	eq(W.spawned[2].workspace, names.beta, "beta renamed")
	eq(W.spawned[3].workspace, names.alpha, "second alpha window")
	eq(W.spawned[2].width, 70, "cell width")
	eq(count_log("set_active_workspace:"), 1, "one workspace switch")
	eq(W.active_workspace, names.alpha, "active workspace")
	eq(#W.gui_requests, 1, "only the focused window asks for a GUI window")
	eq(W.gui_requests[1], windows[3]:window_id(), "focused window")
	eq(count_log("focus:"), 1, "focus once")
	eq(live.workspace, "alpha", "live window workspace")
	eq(#live.tabs_, 1, "live tabs")
	eq(#live.tabs_[1].panes_, 1, "live panes")
	eq(live.tabs_[1].title, "live", "live title")
	eq(#windows[1].tabs_, 2, "tabs restored")
	eq(windows[1].tabs_[1].title, "one", "tab order and titles")
	eq(windows[1].active, windows[1].tabs_[2], "active tab")
	eq(serialize(state), snapshot, "saved state untouched")

	-- the same decoded object can be restored again; cold start keeps original names
	W.spawned = nil
	local again, err2 = session_state.restore(state, restore_opts())
	check(again, err2)
	eq(W.spawned[1].workspace, "alpha", "original names without a mapping")
	eq(W.active_workspace, "alpha", "original active workspace")
	eq(serialize(state), snapshot, "still untouched")
end)

test("a failure mid-restore returns the windows already created and one error", function()
	init_world()
	make_source()
	local state = assert(session_state.capture({ focused_window_id = 9 }))
	init_world()
	local windows, err, partial = session_state.restore(state, {
		spawn_pane = function(leaf)
			if leaf.cwd == "Y" then
				error("spawn exploded")
			end
			return { cwd = leaf.cwd }
		end,
	})
	eq(windows, nil, "no success")
	contains(err, "spawn exploded", "error text")
	eq(#partial, 2, "completed windows retained")
	eq(#W.windows, 2, "no extra windows")
end)

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

local failures = {}
for _, t in ipairs(tests) do
	init_world()
	local ok, err = pcall(t.fn)
	if not ok then
		failures[#failures + 1] = t.name .. ": " .. tostring(err)
	end
end
if #failures > 0 then
	error(#failures .. " of " .. #tests .. " layout tests failed:\n" .. table.concat(failures, "\n"), 0)
end
