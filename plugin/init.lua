-- Resolve the actual loader name for URL plugins and offline vendoring.
-- Loading never creates directories or fetches code.
local module_name = ...
local path, err = package.searchpath(module_name, package.path)
assert(path, err)
local directory = assert(path:match("^(.*)[/\\]init%.lua$"), "Cannot locate resurrect plugin directory")
package.path = directory .. "/?.lua;" .. package.path

return {
  workspace_state = require("resurrect.workspace_state"),
  window_state = require("resurrect.window_state"),
  tab_state = require("resurrect.tab_state"),
  fuzzy_loader = require("resurrect.fuzzy_loader"),
  state_manager = require("resurrect.state_manager"),
  pane_tree = require("resurrect.pane_tree"),
  session_state = require("resurrect.session_state"),
}
