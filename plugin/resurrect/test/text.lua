local wezterm = require("wezterm")
local pub = {}

function pub.write_all_chars(pane)
	-- ascii
	for i = 1, 127 do
		pane:inject_output(string.char(i))
	end
	--utf8
	for i = 128, 31000 do
		pane:inject_output(utf8.char(i))
	end
end

function pub.write_and_save_current_window()
	return wezterm.action_callback(function(win, pane)
		local window_state = require("resurrect.window_state")
		local state_manager = require("resurrect.state_manager")
		local mux_win = win:mux_window()
		pub.write_all_chars(pane)
		mux_win:set_title("TEST_WRITING_CHARS")
		local state, err = window_state.get_window_state(mux_win)
		if not state then
			wezterm.log_error("Could not capture the test window: " .. tostring(err))
			return
		end
		local path, save_err = state_manager.save_state(state)
		if not path then
			wezterm.log_error("Could not save the test window: " .. tostring(save_err))
			return
		end
		wezterm.log_info("SAVED THE WINDOW AS TEST_WRITING_CHARS")
	end)
end

return pub
