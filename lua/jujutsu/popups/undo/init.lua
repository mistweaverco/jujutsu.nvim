local actions = require("jujutsu.popups.undo.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("UndoPopup")
    :group_heading("Undo")
    :action("u", "Undo last operation", actions.undo)
    :action("r", "Redo", actions.redo)
    :action("l", "Operation log", actions.op_log)
    :action("o", "Restore operation", actions.op_restore)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
