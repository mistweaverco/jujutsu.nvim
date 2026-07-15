local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local editor = require("jujutsu.buffers.editor")
local finder = require("jujutsu.finder")

local M = {}

local function no_edit(popup)
  return (popup:get_internal_arguments() or {})["no-edit"] or vim.tbl_contains(popup:get_arguments(), "--no-edit")
end

function M.commit(popup)
  local root = common.root(popup)
  editor.open({
    root = root,
    revision = "@",
    mode = "commit",
    on_submit = function() require("jujutsu").refresh() end,
  })
end

function M.commit_with_bookmark(popup)
  -- Describe, new, then advance bookmarks from parent - simplified: commit then notify
  M.commit(popup)
end

function M.new_change(popup)
  local b = cli.new
  if no_edit(popup) then b = b.no_edit end
  common.run(popup, b)
end

function M.new_change_with_bookmark(popup) M.new_change(popup) end

function M.new_change_on(popup)
  local root = common.root(popup)
  local selected = finder.pick_revision({ prompt = "New change on", cwd = root })
  if selected then
    local b = cli.new.args(selected)
    if no_edit(popup) then b = b.no_edit end
    common.run(popup, b)
  end
end

function M.new_change_on_with_bookmark(popup) M.new_change_on(popup) end

function M.new_change_on_bookmark(popup)
  local root = common.root(popup)
  local selected = finder.pick_bookmark({ prompt = "New change on bookmark", cwd = root })
  if selected then common.run(popup, cli.new.args(selected)) end
end

function M.new_change_before(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Insert before", cwd = root })
  if rev then common.run(popup, cli.new.insert_before.args(rev)) end
end

function M.edit_change(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Edit change", cwd = root })
  if rev then common.run(popup, cli.edit.args(rev)) end
end

function M.describe(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or "@"
  editor.open({
    root = root,
    revision = rev,
    mode = "describe",
    on_submit = function() require("jujutsu").refresh() end,
  })
end

function M.describe_with_message(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or "@"
  vim.ui.input({ prompt = "Description: " }, function(msg)
    if msg and msg ~= "" then
      cli.describe.revision(rev).message(msg).call({ cwd = root, hidden = false })
      require("jujutsu").refresh()
    end
  end)
end

function M.abandon(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Abandon", cwd = root })
  if rev then common.run(popup, cli.abandon.args(rev)) end
end

function M.duplicate(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Duplicate", cwd = root })
  if rev then common.run(popup, cli.duplicate.args(rev)) end
end

function M.revert(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Revert", cwd = root })
  if rev then common.run(popup, cli.revert.revision(rev)) end
end

return M
