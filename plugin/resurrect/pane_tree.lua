local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")

---@class pane_tree_module
---@field max_nlines integer
local pub = {}
pub.max_nlines = 3500

---@alias Pane any
---@alias PaneInformation {left: integer, top: integer, height: integer, width: integer, is_active: boolean?, is_zoomed: boolean?, pane: Pane}
---@alias local_process_info {name: string?, argv: string[]?, cwd: string?, executable: string?}
---@alias pane_leaf {kind: "pane", left: integer, top: integer, width: integer, height: integer, cwd: string, domain: string, text: string?, process: local_process_info?, alt_screen_active: boolean, is_active: boolean, is_zoomed: boolean, metadata: table?, pane: Pane?, restore_notice: string?}
---@alias pane_split {kind: "split", direction: "Right"|"Bottom", first: pane_tree, second: pane_tree, first_extent: integer, second_extent: integer}
---@alias pane_tree pane_leaf | pane_split
---@alias pane_capture_policy {cwd: boolean?, text: boolean?, process: boolean?}
---@alias pane_capture_opts {on_pane_capture: (fun(pane: Pane, leaf: pane_leaf): (pane_capture_policy|false|nil))?, capture_process: boolean?, save_non_local_domains: boolean?, max_nlines: integer?}

-- ---------------------------------------------------------------------------
-- Text handling
-- ---------------------------------------------------------------------------

---Removes everything that could be interpreted as terminal control input and
---normalizes line endings to CRLF. Keeps tab, CR and LF. C1 controls are removed
---as whole UTF-8 codepoints (U+0080..U+009F) so multibyte text is never split.
---@param text string
---@return string
function pub.sanitize_text(text)
	text = text:gsub("[\0-\8\11\12\14-\31\127]", "")
	text = text:gsub("\194[\128-\159]", "")
	text = text:gsub("\r\n", "\n")
	text = text:gsub("\n", "\r\n")
	return text
end

---Keeps only the last `max` lines of text.
---@param text string
---@param max integer
---@return string
function pub.limit_lines(text, max)
	local _, newlines = text:gsub("\n", "")
	if newlines + 1 <= max then
		return text
	end
	local pos = 0
	for _ = 1, newlines + 1 - max do
		pos = text:find("\n", pos + 1, true)
	end
	return text:sub(pos + 1)
end

-- ---------------------------------------------------------------------------
-- Host / cwd helpers
-- ---------------------------------------------------------------------------

---@param host string?
---@return string
local function normalize_host(host)
	host = (host or ""):match("^%s*(.-)%s*$"):lower()
	return (host:gsub("%.$", ""))
end

---Whether an OSC 7 host identifies this machine.
---@param host string?
---@return boolean
function pub.host_is_local(host)
	host = normalize_host(host)
	if host == "" or host == "localhost" then
		return true
	end
	local ok, name = pcall(wezterm.hostname)
	if not ok or type(name) ~= "string" then
		return false
	end
	name = normalize_host(name)
	if host == name then
		return true
	end
	-- A short host equals the first label of the local name.
	if not host:find(".", 1, true) and name:match("^([^.]+)") == host then
		return true
	end
	return false
end

---@param domain string
---@return boolean
local function is_wsl_domain(domain)
	return domain:sub(1, 4) == "WSL:"
end

-- ---------------------------------------------------------------------------
-- Layout: binary slicing tree
-- ---------------------------------------------------------------------------

local function is_int(v)
	return type(v) == "number" and v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge
end

---Recursively tiles `box` with `rects` using full-length divider cuts.
---@return table|nil node
---@return string|nil err
local function slice(rects, box)
	if #rects == 1 then
		local r = rects[1]
		if r.left == box.left and r.top == box.top and r.width == box.width and r.height == box.height then
			return { kind = "pane", rect = r }
		end
		return nil,
			string.format(
				"pane %s at %d,%d %dx%d does not fill its %d,%d %dx%d slot",
				tostring(r.id),
				r.left,
				r.top,
				r.width,
				r.height,
				box.left,
				box.top,
				box.width,
				box.height
			)
	end

	for _, direction in ipairs({ "Right", "Bottom" }) do
		local vertical = direction == "Right"
		local start_key, size_key = "left", "width"
		local box_start, box_size = box.left, box.width
		if not vertical then
			start_key, size_key = "top", "height"
			box_start, box_size = box.top, box.height
		end
		local box_end = box_start + box_size

		-- Candidate divider cells: the cell right after some pane's end.
		local seen, cuts = {}, {}
		for _, r in ipairs(rects) do
			local c = r[start_key] + r[size_key]
			if c < box_end and not seen[c] then
				seen[c] = true
				cuts[#cuts + 1] = c
			end
		end
		table.sort(cuts)

		for _, c in ipairs(cuts) do
			local first, second, ok = {}, {}, true
			for _, r in ipairs(rects) do
				if r[start_key] + r[size_key] <= c then
					first[#first + 1] = r
				elseif r[start_key] >= c + 1 then
					second[#second + 1] = r
				else
					ok = false
					break
				end
			end
			if ok and #first > 0 and #second > 0 then
				-- Slicing is hereditary: when a valid cut exists and its parts
				-- cannot be tiled, no other cut can tile the whole.
				local first_box = { left = box.left, top = box.top, width = box.width, height = box.height }
				local second_box = { left = box.left, top = box.top, width = box.width, height = box.height }
				first_box[size_key] = c - box_start
				second_box[start_key] = c + 1
				second_box[size_key] = box_end - (c + 1)
				local a, aerr = slice(first, first_box)
				if not a then
					return nil, aerr
				end
				local b, berr = slice(second, second_box)
				if not b then
					return nil, berr
				end
				return {
					kind = "split",
					direction = direction,
					first = a,
					second = b,
					first_extent = first_box[size_key],
					second_extent = second_box[size_key],
				}
			end
		end
	end

	return nil, "pane geometry is not a valid tiling (no divider cut found for " .. #rects .. " panes)"
end

---@param node table
---@param out table[]
local function collect_structure_leaves(node, out)
	if node.kind == "pane" then
		out[#out + 1] = node
	else
		collect_structure_leaves(node.first, out)
		collect_structure_leaves(node.second, out)
	end
end

-- ---------------------------------------------------------------------------
-- Capture
-- ---------------------------------------------------------------------------

---@param pane Pane
---@param max integer
---@return string|nil
local function capture_text(pane, max)
	local dims = pane:get_dimensions()
	local nlines = math.min(dims.scrollback_rows or 0, max)
	if dims.viewport_rows and nlines < dims.viewport_rows then
		nlines = math.min(dims.viewport_rows, max)
	end
	if nlines < 1 then
		return nil
	end
	local text = pane:get_lines_as_text(nlines)
	if type(text) ~= "string" then
		return nil
	end
	text = pub.sanitize_text(text)
	-- trailing blank space carries nothing
	text = text:gsub("%s+$", "")
	if text == "" then
		return nil
	end
	return text
end

---@param pane Pane
---@return local_process_info|nil
local function capture_process(pane)
	local ok, info = pcall(pane.get_foreground_process_info, pane)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local process = {}
	for _, key in ipairs({ "name", "cwd", "executable" }) do
		if type(info[key]) == "string" then
			process[key] = info[key]
		end
	end
	if type(info.argv) == "table" then
		local argv = {}
		for i, v in ipairs(info.argv) do
			argv[i] = tostring(v)
		end
		process.argv = argv
	end
	if next(process) == nil then
		return nil
	end
	return process
end

---@param pane Pane
---@param domain string
---@return string
local function capture_cwd(pane, domain)
	local url = pane:get_current_working_dir()
	if not url then
		return ""
	end
	local path = url.file_path
	if type(path) ~= "string" then
		return ""
	end
	if domain == "local" then
		if not pub.host_is_local(url.host) then
			return ""
		end
		if utils.is_windows then
			path = path:gsub("^/(%a):", "%1:")
		end
	end
	return path
end

---@param domain string
---@return boolean
local function domain_is_spawnable(domain)
	local ok, dom = pcall(wezterm.mux.get_domain, domain)
	if not ok or not dom then
		return false
	end
	local ok2, spawnable = pcall(dom.is_spawnable, dom)
	return ok2 and spawnable == true
end

---@param rect table
---@param opts pane_capture_opts
---@return pane_leaf
local function capture_leaf(rect, opts)
	local pane = rect.pane
	local domain = pane:get_domain_name()
	if type(domain) ~= "string" or domain == "" then
		error("pane " .. tostring(rect.id) .. " has no domain")
	end

	local leaf = {
		kind = "pane",
		left = rect.left,
		top = rect.top,
		width = rect.width,
		height = rect.height,
		domain = domain,
		is_active = rect.is_active,
		is_zoomed = rect.is_zoomed,
		alt_screen_active = pane:is_alt_screen_active() == true,
	}

	-- Profile metadata and capture suppression happen BEFORE any cwd, process
	-- or scrollback query, so a suppressed pane is never read.
	local policy = {}
	if opts.on_pane_capture then
		local result = opts.on_pane_capture(pane, leaf)
		if result == false then
			policy = { cwd = false, text = false, process = false }
		elseif type(result) == "table" then
			policy = result
		end
	end

	if policy.cwd ~= false then
		leaf.cwd = capture_cwd(pane, domain)
	else
		leaf.cwd = ""
	end

	local text_allowed = domain == "local" or (opts.save_non_local_domains == true and domain_is_spawnable(domain))
	if policy.text ~= false and text_allowed and not leaf.alt_screen_active then
		leaf.text = capture_text(pane, opts.max_nlines or pub.max_nlines)
	end

	if opts.capture_process == true and policy.process ~= false then
		leaf.process = capture_process(pane)
	end

	return leaf
end

---@param node table
---@param opts pane_capture_opts
---@return pane_tree
local function capture_node(node, opts)
	if node.kind == "pane" then
		return capture_leaf(node.rect, opts)
	end
	return {
		kind = "split",
		direction = node.direction,
		first_extent = node.first_extent,
		second_extent = node.second_extent,
		first = capture_node(node.first, opts),
		second = capture_node(node.second, opts),
	}
end

---Create a pane tree from a single `tab:panes_with_info()` observation.
---Neither the list nor its entries are modified.
---@param panes PaneInformation[]
---@param opts? pane_capture_opts
---@return pane_tree|nil
---@return string|nil err
function pub.create_pane_tree(panes, opts)
	opts = opts or {}
	if type(panes) ~= "table" or #panes == 0 then
		return nil, "tab has no panes"
	end

	local rects, ids = {}, {}
	local active_count, zoom_count = 0, 0
	for i, info in ipairs(panes) do
		if type(info) ~= "table" or info.pane == nil then
			return nil, "pane entry " .. i .. " has no pane handle"
		end
		local ok, id = pcall(info.pane.pane_id, info.pane)
		if not ok or id == nil then
			return nil, "pane entry " .. i .. " is no longer available"
		end
		if ids[id] then
			return nil, "duplicate pane " .. tostring(id) .. " in tab"
		end
		ids[id] = true
		for _, key in ipairs({ "left", "top", "width", "height" }) do
			if not is_int(info[key]) then
				return nil, "pane " .. tostring(id) .. " has invalid " .. key
			end
		end
		if info.left < 0 or info.top < 0 or info.width < 1 or info.height < 1 then
			return nil, "pane " .. tostring(id) .. " has non-positive geometry"
		end
		if info.is_active then
			active_count = active_count + 1
		end
		if info.is_zoomed then
			zoom_count = zoom_count + 1
		end
		rects[i] = {
			id = id,
			pane = info.pane,
			left = info.left,
			top = info.top,
			width = info.width,
			height = info.height,
			is_active = info.is_active == true,
			is_zoomed = info.is_zoomed == true,
		}
	end
	if active_count > 1 then
		return nil, "tab reports more than one active pane"
	end
	if zoom_count > 1 then
		return nil, "tab reports more than one zoomed pane"
	end

	local left, top, right, bottom = math.huge, math.huge, 0, 0
	for _, r in ipairs(rects) do
		left = math.min(left, r.left)
		top = math.min(top, r.top)
		right = math.max(right, r.left + r.width)
		bottom = math.max(bottom, r.top + r.height)
	end
	local structure, err = slice(rects, { left = left, top = top, width = right - left, height = bottom - top })
	if not structure then
		return nil, err
	end

	local ok, tree = pcall(capture_node, structure, opts)
	if not ok then
		return nil, "pane capture failed: " .. tostring(tree)
	end
	return tree
end

-- ---------------------------------------------------------------------------
-- Traversal
-- ---------------------------------------------------------------------------

---@param tree pane_tree
---@return pane_leaf
function pub.first_leaf(tree)
	while tree.kind == "split" do
		tree = tree.first
	end
	return tree
end

---Leaves in restore order (first before second).
---@param tree pane_tree
---@return pane_leaf[]
function pub.leaves(tree)
	local out = {}
	local function walk(node)
		if node.kind == "split" then
			walk(node.first)
			walk(node.second)
		else
			out[#out + 1] = node
		end
	end
	walk(tree)
	return out
end

---Calls f on every leaf in order. Returns the tree.
---@param tree pane_tree
---@param f fun(leaf: pane_leaf): any
---@return pane_tree|nil
function pub.map(tree, f)
	if tree == nil then
		return nil
	end
	for _, leaf in ipairs(pub.leaves(tree)) do
		f(leaf)
	end
	return tree
end

---Folds over every leaf in order.
---@generic A
---@param tree pane_tree|nil
---@param acc A
---@param f fun(acc: A, leaf: pane_leaf): A
---@return A
function pub.fold(tree, acc, f)
	if tree == nil then
		return acc
	end
	for _, leaf in ipairs(pub.leaves(tree)) do
		acc = f(acc, leaf)
	end
	return acc
end

---Minimum (cols, rows) a region needs to hold the tree, counting one divider cell per split.
---@param tree pane_tree
---@return integer cols
---@return integer rows
function pub.min_size(tree)
	if tree.kind == "pane" then
		return 1, 1
	end
	local fc, fr = pub.min_size(tree.first)
	local sc, sr = pub.min_size(tree.second)
	if tree.direction == "Right" then
		return fc + 1 + sc, math.max(fr, sr)
	end
	return math.max(fc, sc), fr + 1 + sr
end

local MAX_DEPTH = 256

---Validates the complete tree shape without touching any live object.
---@param tree any
---@return boolean|nil ok
---@return string|nil err
function pub.validate(tree)
	local counts = { panes = 0, active = 0, zoomed = 0 }

	local function opt(node, key, kind, where)
		local v = node[key]
		if v ~= nil and type(v) ~= kind then
			error(where .. "." .. key .. " must be a " .. kind)
		end
	end

	---@return table bbox
	local function check(node, depth, where)
		if type(node) ~= "table" then
			error(where .. " is not a table")
		end
		if depth > MAX_DEPTH then
			error("pane tree is too deep")
		end
		if node.kind == "pane" then
			for _, key in ipairs({ "left", "top", "width", "height" }) do
				if not is_int(node[key]) then
					error(where .. "." .. key .. " must be an integer")
				end
			end
			if node.left < 0 or node.top < 0 or node.width < 1 or node.height < 1 then
				error(where .. " has non-positive geometry")
			end
			opt(node, "cwd", "string", where)
			opt(node, "domain", "string", where)
			opt(node, "text", "string", where)
			opt(node, "alt_screen_active", "boolean", where)
			opt(node, "is_active", "boolean", where)
			opt(node, "is_zoomed", "boolean", where)
			opt(node, "process", "table", where)
			opt(node, "metadata", "table", where)
			counts.panes = counts.panes + 1
			if node.is_active then
				counts.active = counts.active + 1
			end
			if node.is_zoomed then
				counts.zoomed = counts.zoomed + 1
			end
			return { left = node.left, top = node.top, width = node.width, height = node.height }
		elseif node.kind == "split" then
			if node.direction ~= "Right" and node.direction ~= "Bottom" then
				error(where .. ".direction must be Right or Bottom")
			end
			if not is_int(node.first_extent) or not is_int(node.second_extent) then
				error(where .. " extents must be integers")
			end
			if node.first_extent < 1 or node.second_extent < 1 then
				error(where .. " extents must be positive")
			end
			local a = check(node.first, depth + 1, where .. ".first")
			local b = check(node.second, depth + 1, where .. ".second")
			if node.direction == "Right" then
				if
					a.width ~= node.first_extent
					or b.width ~= node.second_extent
					or a.height ~= b.height
					or a.top ~= b.top
					or b.left ~= a.left + a.width + 1
				then
					error(where .. " children do not match their split geometry")
				end
				return { left = a.left, top = a.top, width = a.width + 1 + b.width, height = a.height }
			end
			if
				a.height ~= node.first_extent
				or b.height ~= node.second_extent
				or a.width ~= b.width
				or a.left ~= b.left
				or b.top ~= a.top + a.height + 1
			then
				error(where .. " children do not match their split geometry")
			end
			return { left = a.left, top = a.top, width = a.width, height = a.height + 1 + b.height }
		end
		error(where .. ".kind must be pane or split")
	end

	local ok, err = pcall(check, tree, 1, "pane_tree")
	if not ok then
		return nil, (tostring(err):gsub("^[^:]*:%d+: ", ""))
	end
	if counts.active > 1 then
		return nil, "pane_tree has more than one active pane"
	end
	if counts.zoomed > 1 then
		return nil, "pane_tree has more than one zoomed pane"
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

---Default safe spawn description for a saved pane. Never replays commands.
---
---* `local` panes (and configured `WSL:*` domains) start the default shell in the
---  saved folder; a missing/unreadable native folder is dropped and reported
---  through `opts.warn(message)`.
---* Every other domain (SSH, SSHMUX, unix, TLS, unknown, or a missing WSL domain)
---  becomes a local shell plus a `notice` string. Nothing connects automatically.
---
---Restore functions pass their own restore options as `opts` and provide
---`opts.warn` and `opts.cwd_cache`. A custom `spawn_pane(leaf, opts)` may delegate
---here: `return pane_tree.default_spawn_pane(leaf, opts)`.
---@param leaf pane_leaf
---@param opts? table
---@return table spawn_command  Argument table for spawn_window/spawn_tab/pane:split
---@return string|nil notice  Local text to show in the restored pane
function pub.default_spawn_pane(leaf, opts)
	opts = opts or {}
	local warn = opts.warn or function() end
	local cache = opts.cwd_cache or {}
	local domain = leaf.domain
	local cmd = {}
	local notice

	local cwd = leaf.cwd
	if type(cwd) ~= "string" or cwd == "" then
		cwd = nil
	end

	if domain == nil or domain == "" or domain == "local" then
		if cwd then
			if utils.is_windows then
				cwd = cwd:gsub("^/(%a):", "%1:")
			end
			local status = cache[cwd]
			if status == nil then
				local ok = pcall(wezterm.read_dir, cwd)
				status = ok
				cache[cwd] = status
				if not ok then
					warn("Folder unavailable, opened in the default directory: " .. cwd)
				end
			end
			if status then
				cmd.cwd = cwd
			end
		end
	elseif is_wsl_domain(domain) then
		local ok, dom = pcall(wezterm.mux.get_domain, domain)
		if ok and dom then
			cmd.domain = { DomainName = domain }
			cmd.cwd = cwd
		else
			notice = "Domain " .. domain .. " is unavailable; opened a local shell"
		end
	else
		notice = "Remote domain " .. domain .. " is disconnected; use the Domains launcher to attach"
	end

	return cmd, notice
end

return pub
