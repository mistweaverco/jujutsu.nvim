local actions = require("jujutsu.popups.log.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("LogPopup")
    :option("r", "revisions", "all()", "Revset", { cli_prefix = "-", separator = " " })
    :group_heading("Log")
    :action("l", "Log", actions.log)
    :action("a", "All", actions.log_all)
    :action("h", "Head ancestors", actions.log_head)
    :action("o", "Open revset", actions.log_revset)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
