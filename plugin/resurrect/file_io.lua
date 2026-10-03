local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")

local pub = {
	encryption = { enable = false },
}

-- Whether a regular file can be opened for reading.
---@param path string
---@return boolean
function pub.path_exists(path)
	local handle = io.open(path, "rb")
	if handle then
		handle:close()
		return true
	end
	return false
end

-- Write a file with the content of a string. The write, flush and close results
-- are all checked; a partially written file is left for the caller to clean up.
---@param file_path string full filename
---@param str string
---@return true|nil ok
---@return string|nil error
function pub.write_file(file_path, str)
	local handle, open_err = io.open(file_path, "wb")
	if not handle then
		return nil, tostring(open_err)
	end
	local ok, err = handle:write(str)
	if not ok then
		handle:close()
		return nil, "Could not write " .. file_path .. ": " .. tostring(err)
	end
	ok, err = handle:flush()
	if not ok then
		handle:close()
		return nil, "Could not flush " .. file_path .. ": " .. tostring(err)
	end
	ok, err = handle:close()
	if not ok then
		return nil, "Could not close " .. file_path .. ": " .. tostring(err)
	end
	return true
end

-- Read a whole file.
---@param file_path string full filename
---@return string|nil content
---@return string|nil error
---@return "missing"|"io"|nil kind  why reading failed
function pub.read_file(file_path)
	local handle, open_err, errno = io.open(file_path, "rb")
	if not handle then
		return nil, tostring(open_err), errno == 2 and "missing" or "io"
	end
	local content, err = handle:read("a")
	handle:close()
	if content == nil then
		return nil, "Could not read " .. file_path .. ": " .. tostring(err), "io"
	end
	return content
end

--- Merges user-supplied options with default options
--- @param user_opts encryption_opts
function pub.set_encryption(user_opts)
	pub.encryption = require("resurrect.encryption")
	for k, v in pairs(user_opts) do
		if v ~= nil then
			pub.encryption[k] = v
		end
	end
end

--- Sanitize the input by replacing control characters and invalid UTF-8 sequences with valid \uxxxx unicode
--- @param data string
--- @return string
local function sanitize_json(data)
	wezterm.emit("resurrect.file_io.sanitize_json.start", data)
	-- escapes control characters to ensure valid json
	data = data:gsub("[\x00-\x1F]", function(c)
		return string.format("\\u00%02X", string.byte(c))
	end)
	wezterm.emit("resurrect.file_io.sanitize_json.finished")
	return data
end

-- Serialize a state to the JSON text that is stored on disk.
---@param state table
---@return string|nil json
---@return string|nil error
function pub.encode_json(state)
	local ok, json = pcall(wezterm.json_encode, state)
	if not ok then
		return nil, "Could not serialize state: " .. tostring(json)
	end
	return sanitize_json(json)
end

-- Parse stored JSON text; the document must be an object or array.
---@param text string
---@return table|nil state
---@return string|nil error
function pub.parse_json(text)
	-- Files are written compact; raw line breaks only come from hand editing.
	text = sanitize_json((text:gsub("[\r\n]", "")))
	local ok, parsed = pcall(wezterm.json_parse, text)
	if not ok then
		return nil, "Invalid JSON: " .. tostring(parsed):match("^[^\n]*")
	end
	if type(parsed) ~= "table" then
		return nil, "Invalid JSON: document is not an object or array"
	end
	return parsed
end

-- Read and parse a plain (never encrypted) JSON file.
---@param file_path string
---@return table|nil state
---@return string|nil error
---@return "missing"|"io"|"invalid"|nil kind
function pub.load_plain_json(file_path)
	local text, err, kind = pub.read_file(file_path)
	if not text then
		return nil, err, kind
	end
	local parsed, parse_err = pub.parse_json(text)
	if not parsed then
		return nil, file_path .. ": " .. parse_err, "invalid"
	end
	return parsed
end

-- Read and parse a state file, decrypting it when encryption is enabled.
---@param file_path string
---@return table|nil state
---@return string|nil error
---@return "missing"|"io"|"invalid"|nil kind
function pub.load_json(file_path)
	if not pub.encryption.enable then
		return pub.load_plain_json(file_path)
	end
	if not pub.path_exists(file_path) then
		return nil, "Could not open file: " .. file_path, "missing"
	end
	wezterm.emit("resurrect.file_io.decrypt.start", file_path)
	local ok, output = pcall(pub.encryption.decrypt, file_path)
	if not ok then
		return nil, "Decryption failed: " .. tostring(output), "invalid"
	end
	wezterm.emit("resurrect.file_io.decrypt.finished", file_path)
	local parsed, err = pub.parse_json(output)
	if not parsed then
		return nil, file_path .. ": " .. err, "invalid"
	end
	return parsed
end

local function next_counter()
	local n = (wezterm.GLOBAL.resurrect_path_counter or 0) + 1
	wezterm.GLOBAL.resurrect_path_counter = n
	return n
end

-- A sibling path that does not exist yet, built from a process-wide counter:
-- "<path>.<os.time()>.<n>.tmp" for kind "tmp", "<path>.corrupt.<n>" for "corrupt".
---@param path string
---@param kind "tmp"|"corrupt"
---@return string|nil unused
---@return string|nil error
function pub.unused_path(path, kind)
	for _ = 1, 10000 do
		local n = next_counter()
		local candidate
		if kind == "tmp" then
			candidate = string.format("%s.%d.%d.tmp", path, os.time(), n)
		elseif kind == "corrupt" then
			candidate = string.format("%s.corrupt.%d", path, n)
		else
			return nil, "unknown unused-path kind: " .. tostring(kind)
		end
		if not pub.path_exists(candidate) then
			return candidate
		end
	end
	return nil, "Could not find an unused name next to " .. path
end

-- Move a damaged file aside to an unused ".corrupt.<n>" name so its bytes
-- survive for recovery.
---@param path string
---@return string|nil new_path
---@return string|nil error
function pub.quarantine(path)
	local target, err = pub.unused_path(path, "corrupt")
	if not target then
		return nil, err
	end
	local ok, rename_err = os.rename(path, target)
	if not ok then
		return nil, "Could not move damaged file " .. path .. " aside: " .. tostring(rename_err)
	end
	return target
end

-- Remove a leftover temp file after a failed publication and return `detail`
-- with any cleanup failure appended, so the original error is never lost.
---@param temp string
---@param detail string
---@return string
function pub.discard_temp(temp, detail)
	local removed, remove_err = os.remove(temp)
	if not removed and pub.path_exists(temp) then
		return detail .. "; also could not remove temporary file " .. temp .. ": " .. tostring(remove_err)
	end
	return detail
end

-- Write `text` to a unique temp file next to `destination`, check that `validate`
-- accepts the completed file, and return the temp path (caller publishes it).
---@param destination string
---@param writer fun(temp: string): true|nil, string|nil
---@param validate fun(temp: string): any, string|nil
---@return string|nil temp
---@return string|nil error
local function stage(destination, writer, validate)
	local temp, err = pub.unused_path(destination, "tmp")
	if not temp then
		return nil, err
	end
	local ok, write_err = writer(temp)
	if ok then
		ok, write_err = validate(temp)
	end
	if not ok then
		return nil, pub.discard_temp(temp, tostring(write_err))
	end
	return temp
end

-- Publish a plain JSON document without keeping a backup; used for small
-- single-owner markers. An existing valid file (and one accepted by `validate`)
-- is left untouched and the call succeeds. A malformed existing file is moved to
-- an unused ".corrupt.<n>" name before the replacement is published, and the
-- completed temp file is parsed back before it becomes visible.
---@param path string
---@param state table
---@param validate? fun(state: table): true|nil, string|nil
---@return true|nil ok
---@return string|nil error
function pub.publish_json(path, state, validate)
	local function check(parsed)
		if validate then
			return validate(parsed)
		end
		return true
	end

	if pub.path_exists(path) then
		local existing = pub.load_plain_json(path)
		if existing and check(existing) then
			return true
		end
		local _, quarantine_err = pub.quarantine(path)
		if quarantine_err then
			return nil, quarantine_err
		end
	end

	local json, encode_err = pub.encode_json(state)
	if not json then
		return nil, encode_err
	end
	local folder_ok, folder_err = utils.ensure_folder_exists(utils.dirname(path))
	if not folder_ok then
		return nil, folder_err
	end
	local temp, stage_err = stage(path, function(temp)
		return pub.write_file(temp, json)
	end, function(temp)
		local parsed, err = pub.load_plain_json(temp)
		if not parsed then
			return nil, err
		end
		return check(parsed)
	end)
	if not temp then
		return nil, stage_err
	end
	local renamed, rename_err = os.rename(temp, path)
	if not renamed then
		return nil, pub.discard_temp(temp, "Could not publish " .. path .. ": " .. tostring(rename_err))
	end
	return true
end

-- Stage plain JSON text next to `destination` in a unique temp file, parse the
-- completed file back and require `check` (optional) to accept it. Returns the
-- temp path; the caller publishes it with os.rename or removes it.
---@param destination string
---@param json string
---@param check? fun(state: table): true|nil, string|nil
---@return string|nil temp
---@return string|nil error
function pub.stage_plain_json(destination, json, check)
	return stage(destination, function(temp)
		return pub.write_file(temp, json)
	end, function(temp)
		local parsed, err = pub.load_plain_json(temp)
		if not parsed then
			return nil, err
		end
		if check then
			return check(parsed)
		end
		return true
	end)
end

-- Publish a completed, validated temp file as `destination`, keeping the previous
-- good version as "<destination>.bak". The temp file is removed on failure.
---@param temp string
---@param destination string
---@return true|nil ok
---@return string|nil error
local function publish_with_backup(temp, destination)
	local backup = destination .. ".bak"
	local moved_to_backup = false

	if pub.path_exists(destination) then
		if pub.load_json(destination) then
			-- Rename cannot replace an existing file on Windows: drop the older
			-- backup first, while the valid destination is still in place.
			if pub.path_exists(backup) then
				local removed, remove_err = os.remove(backup)
				if not removed then
					return nil,
						pub.discard_temp(temp, "Could not replace backup " .. backup .. ": " .. tostring(remove_err))
				end
			end
			local moved, move_err = os.rename(destination, backup)
			if not moved then
				return nil, pub.discard_temp(temp, "Could not back up " .. destination .. ": " .. tostring(move_err))
			end
			moved_to_backup = true
		else
			-- Keep the damaged bytes and any valid backup.
			local _, quarantine_err = pub.quarantine(destination)
			if quarantine_err then
				return nil, pub.discard_temp(temp, tostring(quarantine_err))
			end
		end
	end

	local published, publish_err = os.rename(temp, destination)
	if not published then
		local detail = "Could not publish " .. destination .. ": " .. tostring(publish_err)
		if moved_to_backup then
			local restored, restore_err = os.rename(backup, destination)
			if not restored then
				detail = detail .. "; previous version remains at " .. backup .. " (" .. tostring(restore_err) .. ")"
			end
		end
		return nil, pub.discard_temp(temp, detail)
	end
	return true
end

---@param file_path string
---@param state table
---@param event_type "workspace" | "window" | "tab"
---@return true|nil ok
---@return string|nil error
function pub.write_state(file_path, state, event_type)
	wezterm.emit("resurrect.file_io.write_state.start", file_path, event_type)

	local function fail(message)
		wezterm.emit("resurrect.error", message)
		wezterm.log_error(message)
		return nil, message
	end

	local json, encode_err = pub.encode_json(state)
	if not json then
		return fail(encode_err)
	end

	local temp, stage_err = stage(file_path, function(temp)
		if pub.encryption.enable then
			wezterm.emit("resurrect.file_io.encrypt.start", file_path)
			local ok, err = pcall(pub.encryption.encrypt, temp, json)
			if not ok then
				return nil, "Encryption failed: " .. tostring(err)
			end
			wezterm.emit("resurrect.file_io.encrypt.finished", file_path)
			return true
		end
		local ok, err = pub.write_file(temp, json)
		if not ok then
			return nil, "Failed to write state: " .. err
		end
		return true
	end, function(temp)
		-- Decrypts first when encryption is enabled; ciphertext is never parsed.
		local parsed, err = pub.load_json(temp)
		if not parsed then
			return nil, "Written state failed validation: " .. err
		end
		return true
	end)
	if not temp then
		return fail(stage_err)
	end

	local published, publish_err = publish_with_backup(temp, file_path)
	if not published then
		return fail(publish_err)
	end
	wezterm.emit("resurrect.file_io.write_state.finished", file_path, event_type)
	return true
end

-- Load a named state: the destination if it is valid, otherwise its backup.
---@param file_path string
---@return table|nil state
---@return string|nil error
---@return "missing"|"invalid"|"backup"|"primary"|nil kind  "backup" when the previous version was used
function pub.load_state_file(file_path)
	local state, err, kind = pub.load_json(file_path)
	if state then
		return state, nil, "primary"
	end
	local backup_state, backup_err, backup_kind = pub.load_json(file_path .. ".bak")
	if backup_state then
		return backup_state, "Using the previous good version because " .. tostring(err), "backup"
	end
	if kind == "missing" and backup_kind == "missing" then
		return nil, "State not found: " .. file_path, "missing"
	end
	return nil, tostring(kind ~= "missing" and err or backup_err), "invalid"
end

return pub
