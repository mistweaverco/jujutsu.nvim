local actions = require("jujutsu.popups.split.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("SplitPopup")
    :switch("p", "parallel", "Parallel (siblings)", { cli_prefix = "--" })
    :group_heading("Split")
    :action("s", "Split (interactive)", actions.split, { persist_popup = true })
    :action("f", "Split file / selected hunks", actions.split_file)
    :action("o", "Split onto", actions.split_onto, { persist_popup = true })
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
