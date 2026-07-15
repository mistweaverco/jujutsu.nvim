local actions = require("jujutsu.popups.rebase.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("RebasePopup")
    :switch("k", "skip-emptied", "Skip emptied", { cli_prefix = "--" })
    :group_heading("Rebase")
    :action("r", "Rebase revision", actions.rebase_revision)
    :action("s", "Rebase source", actions.rebase_source)
    :action("d", "Rebase onto destination", actions.rebase_destination)
    :action("b", "Rebase bookmark", actions.rebase_bookmark)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
