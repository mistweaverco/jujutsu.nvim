local actions = require("jujutsu.popups.change.actions")
local builder = require("jujutsu.popup.builder")

local M = {}

function M.create(env)
  local p = builder
    .builder()
    :name("ChangePopup")
    :arg_heading("Flags")
    :switch("e", "no-edit", "Don't edit the new change", { cli_prefix = "--" })
    :group_heading("Create")
    :action("c", "Commit", actions.commit)
    :action("C", "Commit (move bookmarks)", actions.commit_with_bookmark)
    :action("n", "New change", actions.new_change)
    :action("N", "New change (move bookmarks)", actions.new_change_with_bookmark)
    :action("o", "New change on", actions.new_change_on)
    :action("O", "New change on (move bookmarks)", actions.new_change_on_with_bookmark)
    :action("p", "New change on bookmark", actions.new_change_on_bookmark)
    :action("b", "New change before", actions.new_change_before)
    :action("e", "Edit change", actions.edit_change)
    :new_action_group("Describe")
    :action("d", "Describe (editor)", actions.describe)
    :action("D", "Describe (message)", actions.describe_with_message)
    :new_action_group("Modify")
    :action("a", "Abandon", actions.abandon)
    :action("u", "Duplicate", actions.duplicate)
    :action("r", "Revert", actions.revert)
    :action("s", "Split", actions.split)
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
