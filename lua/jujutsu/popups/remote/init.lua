local actions = require("jujutsu.popups.remote.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("RemotePopup")
    :group_heading("Remote")
    :action("a", "Add", actions.add)
    :action("r", "Remove", actions.remove)
    :action("n", "Rename", actions.rename)
    :action("l", "List", actions.list)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
