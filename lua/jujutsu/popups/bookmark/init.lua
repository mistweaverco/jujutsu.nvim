local actions = require("jujutsu.popups.bookmark.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("BookmarkPopup")
    :group_heading("Create")
    :action("c", "Create", actions.create)
    :action("s", "Set", actions.set)
    :action("m", "Move", actions.move)
    :new_action_group("Delete")
    :action("d", "Delete", actions.delete)
    :action("f", "Forget", actions.forget)
    :new_action_group("Track")
    :action("t", "Track", actions.track)
    :action("u", "Untrack", actions.untrack)
    :action("r", "Rename", actions.rename)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
