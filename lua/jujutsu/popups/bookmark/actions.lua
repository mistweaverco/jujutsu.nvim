local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")

local M = {}

function M.create(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or "@"
  vim.ui.input({ prompt = "Bookmark name: " }, function(name)
    if name and name ~= "" then
      cli.bookmark_create.revision(rev).args(name).call({ cwd = root, hidden = false })
      require("jujutsu").refresh()
    end
  end)
end

function M.set(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Set bookmark on", cwd = root })
  if not rev then return end
  vim.ui.input({ prompt = "Bookmark name: " }, function(name)
    if name and name ~= "" then
      cli.bookmark_set.revision(rev).args(name).call({ cwd = root, hidden = false })
      require("jujutsu").refresh()
    end
  end)
end

function M.move(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Move bookmark", cwd = root })
  if not bm then return end
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Move to revision", cwd = root })
  if rev then common.run(popup, cli.bookmark_move.to(rev).args(bm)) end
end

function M.delete(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Delete bookmark", cwd = root })
  if bm then common.run(popup, cli.bookmark_delete.args(bm)) end
end

function M.forget(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Forget bookmark", cwd = root })
  if bm then common.run(popup, cli.bookmark_forget.args(bm)) end
end

function M.track(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Track bookmark", cwd = root })
  if bm then common.run(popup, require("jujutsu.jj.bookmark").track(bm)) end
end

function M.untrack(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Untrack bookmark", cwd = root })
  if bm then common.run(popup, require("jujutsu.jj.bookmark").untrack(bm)) end
end

function M.rename(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Rename bookmark", cwd = root })
  if not bm then return end
  vim.ui.input({ prompt = "New name: ", default = bm }, function(name)
    if name and name ~= "" then
      cli.bookmark_rename.args(bm, name).call({ cwd = root, hidden = false })
      require("jujutsu").refresh()
    end
  end)
end

return M
