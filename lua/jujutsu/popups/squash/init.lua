local actions = require("jujutsu.popups.squash.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("SquashPopup")
    :switch("k", "keep-emptied", "Keep emptied", { cli_prefix = "--" })
    :switch("u", "use-destination-message", "Use destination message", { cli_prefix = "--" })
    :group_heading("Squash")
    :action("s", "Squash into parent", actions.squash_parent)
    :action("i", "Squash into", actions.squash_into)
    :action("f", "Squash from", actions.squash_from)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
