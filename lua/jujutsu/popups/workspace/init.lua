local actions = require("jujutsu.popups.workspace.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("WorkspacePopup")
    :group_heading("Workspace")
    :action("a", "Add", actions.add)
    :action("w", "Quick add (worktrees dir)", actions.quick_add)
    :action("f", "Forget", actions.forget)
    :action("r", "Rename", actions.rename)
    :action("l", "List", actions.list)
    :action("u", "Update stale", actions.update_stale)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
