local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local utils = {}

utils.is_windows = wezterm.target_triple:find("windows", 1, true) ~= nil
utils.separator = utils.is_windows and "\\" or "/"

-- Helper function to remove formatting esc sequences in the string
---@param str string
---@return string
function utils.strip_format_esc_seq(str)
	local clean_str, _ = str:gsub(string.char(27) .. "%[[^m]*m", "")
	return clean_str
end

-- getting screen dimensions
---@return number
function utils.get_current_window_width()
	local windows = wezterm.gui.gui_windows()
	for _, window in ipairs(windows) do
		if window:is_focused() then
			return window:active_tab():get_size().cols
		end
	end
	return 80
end

-- replace the center of a string with another string
---@param str string string to be modified
---@param len number length to be removed from the middle of str
---@param pad string string that must be inserted in place of the missing part of str
function utils.replace_center(str, len, pad)
	local mid = #str // 2
	local start = mid - (len // 2)
	return str:sub(1, start) .. pad .. str:sub(start + len + 1)
end

-- returns the length of a utf8 string
---@param str string
---@return number
function utils.utf8len(str)
	local _, len = str:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
	return len
end

-- Whether the path is a rooted absolute path for the current platform.
-- Windows: a drive root (C:\ or C:/) or a UNC path. Anything else, including
-- drive-relative (C:foo) and current-drive-rooted (\foo) paths, is not absolute.
---@param path string
---@return boolean
function utils.is_absolute_path(path)
	if type(path) ~= "string" then
		return false
	end
	if utils.is_windows then
		return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\][^/\\]") ~= nil
	end
	return path:sub(1, 1) == "/"
end

-- Join path components with exactly one separator between them. A leading POSIX
-- root, Windows drive root and UNC prefix are preserved; empty components are
-- skipped. On Windows the result uses backslashes throughout. The platform is
-- read from utils.is_windows at call time.
---@param ... string
---@return string
function utils.join_path(...)
	local win = utils.is_windows
	local sep = win and "\\" or "/"
	local seps = win and "[/\\]+$" or "/+$"
	local lead = win and "^[/\\]+" or "^/+"
	local result
	for i = 1, select("#", ...) do
		local part = select(i, ...)
		if type(part) ~= "string" then
			error("join_path: component " .. i .. " is " .. type(part) .. ", expected string", 2)
		end
		if part ~= "" then
			if result == nil then
				local stripped = part:gsub(seps, "")
				if stripped == "" then
					result = sep
				elseif win and stripped:match("^%a:$") and stripped ~= part then
					result = stripped .. sep
				else
					result = stripped
				end
			else
				local stripped = part:gsub(lead, ""):gsub(seps, "")
				if stripped ~= "" then
					if result:sub(-1) ~= sep then
						result = result .. sep
					end
					result = result .. stripped
				end
			end
		end
	end
	result = result or ""
	if win then
		result = result:gsub("/", "\\")
	end
	return result
end

-- Last component of a path.
---@param path string
---@return string
function utils.basename(path)
	local stripped = path:gsub(utils.is_windows and "[/\\]+$" or "/+$", "")
	return stripped:match(utils.is_windows and "[^/\\]*$" or "[^/]*$")
end

-- Everything before the last component, without the trailing separator.
-- A path without a directory part returns ".".
---@param path string
---@return string
function utils.dirname(path)
	local win = utils.is_windows
	local stripped = path:gsub(win and "[/\\]+$" or "/+$", "")
	local dir = stripped:match(win and "^(.*)[/\\][^/\\]*$" or "^(.*)/[^/]*$")
	if dir == nil then
		return "."
	end
	if dir == "" then
		return win and "\\" or "/"
	end
	if win and dir:match("^%a:$") then
		return dir .. "\\"
	end
	return dir
end

-- Reversible, filesystem-safe file stem for a user supplied state name:
-- "s-" followed by the lowercase hex of the UTF-8 bytes. Distinct names can
-- never collide, case differences survive case-insensitive filesystems, and the
-- result can never be a device name or traversal component.
---@param name string
---@return string
function utils.encode_state_name(name)
	if type(name) ~= "string" then
		error("encode_state_name: name must be a string, got " .. type(name), 2)
	end
	return "s-" .. name:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end)
end

-- Inverse of encode_state_name; nil if the stem is not one of ours.
---@param stem string
---@return string|nil
function utils.decode_state_name(stem)
	if type(stem) ~= "string" then
		return nil
	end
	local hex = stem:match("^s%-([0-9a-f]*)$")
	if hex == nil or #hex % 2 ~= 0 then
		return nil
	end
	return (hex:gsub("%x%x", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- Double the characters PowerShell treats as single quotes inside '...' literals.
local function powershell_literal(value)
	for _, quote in ipairs({ "'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) do
		value = value:gsub(quote, quote .. quote)
	end
	return "'" .. value .. "'"
end

-- Classify `path` without creating it: "directory" when listable, "missing"
-- when it provably does not exist (an ancestor lists without it, or is itself
-- missing), otherwise nil plus the real error. A name that exists but cannot be
-- listed (a file, a permission failure) is an error, never "missing".
---@param path string
---@return "directory"|"missing"|nil state
---@return string|nil error
function utils.directory_state(path)
	local ok, listing = pcall(wezterm.read_dir, path)
	if ok then
		return "directory"
	end
	local parent = utils.dirname(path)
	if parent == path or parent == "." then
		return nil, "Cannot read folder " .. path .. ": " .. tostring(listing)
	end
	local parent_state, parent_err = utils.directory_state(parent)
	if parent_state == "missing" then
		return "missing"
	end
	if parent_state ~= "directory" then
		return nil, parent_err
	end
	local parent_ok, siblings = pcall(wezterm.read_dir, parent)
	if not parent_ok then
		return nil, "Cannot read folder " .. parent .. ": " .. tostring(siblings)
	end
	local wanted = utils.basename(path)
	for _, sibling in ipairs(siblings) do
		local name = utils.basename(sibling)
		if name == wanted or (utils.is_windows and name:lower() == wanted:lower()) then
			return nil, "Cannot read folder " .. path .. ": " .. tostring(listing)
		end
	end
	return "missing"
end

-- Create a directory, including parents, when it is missing. An existing
-- directory succeeds without starting a process. Creation uses a hidden child
-- process (PowerShell on Windows, argv-form mkdir elsewhere) whose exit status
-- and result are checked; it yields, so call it from event callbacks.
---@param path string
---@return true|nil ok
---@return string|nil error
function utils.ensure_folder_exists(path)
	if type(path) ~= "string" or path == "" then
		return nil, "Folder path must be a non-empty string"
	end
	if path:find("[%z\1-\31]") then
		return nil, "Folder path contains control characters: " .. path:gsub("[%z\1-\31]", "?")
	end
	if utils.is_windows and (path:match("^%a:$") or path:match("^%a:[^/\\]")) then
		return nil, "Drive-relative path is not supported: " .. path
	end
	if pcall(wezterm.read_dir, path) then
		return true
	end

	local args
	if utils.is_windows then
		if path:find('"', 1, true) then
			return nil, 'Folder path contains a double quote: ' .. path
		end
		local expression = "$ErrorActionPreference='Stop'; [IO.Directory]::CreateDirectory("
			.. powershell_literal(path)
			.. ") | Out-Null"
		args = { "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", expression }
	else
		args = { "mkdir", "-p", "--", path }
	end
	local ran, success, _, stderr = pcall(wezterm.run_child_process, args)
	if not ran then
		return nil, "Could not create folder " .. path .. ": " .. tostring(success)
	end
	if not success then
		return nil, "Could not create folder " .. path .. ": " .. tostring(stderr):gsub("%s+$", "")
	end
	local ok, err = pcall(wezterm.read_dir, path)
	if not ok then
		return nil, "Folder was not created: " .. path .. ": " .. tostring(err)
	end
	return true
end

-- deep copy
---@param original table
---@return any copy
function utils.deepcopy(original)
	local copy
	if type(original) == "table" then
		copy = {}
		for k, v in pairs(original) do
			copy[k] = utils.deepcopy(v)
		end
	else
		copy = original
	end
	return copy
end

-- extend table
---@alias behavior
---| 'error' # Raises an error if a kye exists in multiple tables
---| 'keep'  # Uses the value from the leftmost table (first occurrence)
---| 'force' # Uses the value from the rightmost table (last occurrence)
---
---@param behavior behavior
---@param ... table
---@return table|nil
function utils.tbl_deep_extend(behavior, ...)
	local tables = { ... }
	if #tables == 0 then
		return {}
	end

	local result = {}
	for k, v in pairs(tables[1]) do
		if type(v) == "table" then
			result[k] = utils.deepcopy(v)
		else
			result[k] = v
		end
	end

	for i = 2, #tables do
		for k, v in pairs(tables[i]) do
			if type(result[k]) == "table" and type(v) == "table" then
				-- For nested tables, we recurse with the same behavior
				result[k] = utils.tbl_deep_extend(behavior, result[k], v)
			elseif result[k] ~= nil then
				-- Key exists in the result already
				if behavior == "error" then
					error("Key '" .. tostring(k) .. "' exists in multiple tables")
				elseif behavior == "force" then
					-- "force" uses value from rightmost table
					if type(v) == "table" then
						result[k] = utils.deepcopy(v)
					else
						result[k] = v
					end
				end
			-- "keep" keeps the leftmost value, which is already in result
			else
				-- Key doesn't exist in result yet, add it
				if type(v) == "table" then
					result[k] = utils.deepcopy(v)
				else
					result[k] = v
				end
			end
		end
	end

	return result
end

return utils
