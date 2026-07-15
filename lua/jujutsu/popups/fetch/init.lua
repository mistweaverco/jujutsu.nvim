local actions = require("jujutsu.popups.fetch.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("FetchPopup")
    :switch("a", "all-remotes", "All remotes", { cli_prefix = "--", enabled = true })
    :group_heading("Fetch")
    :action("f", "Fetch", actions.fetch)
    :action("r", "Fetch from remote", actions.fetch_remote)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
