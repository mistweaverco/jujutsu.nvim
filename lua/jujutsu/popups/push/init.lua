local actions = require("jujutsu.popups.push.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("PushPopup")
    :switch("d", "deleted", "Push deleted bookmarks", { cli_prefix = "--" })
    :switch("n", "dry-run", "Dry run", { cli_prefix = "--" })
    :switch("a", "all", "All bookmarks", { cli_prefix = "--" })
    :group_heading("Push")
    :action("p", "Push", actions.push)
    :action("b", "Push bookmark", actions.push_bookmark)
    :action("c", "Push change", actions.push_change)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
