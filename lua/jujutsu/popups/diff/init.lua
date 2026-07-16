local actions = require("jujutsu.popups.diff.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("DiffPopup")
    :group_heading("Diff")
    :action("d", "Working copy", actions.working_copy)
    :action("c", "Change", actions.change)
    :action("r", "Range", actions.range)
    :action("t", "Trunk..@", actions.trunk)
    :action("e", "Diffedit", actions.diffedit, { persist_popup = true })
    :action("v", "External viewer", actions.external)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
