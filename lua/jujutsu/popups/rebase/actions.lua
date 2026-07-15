local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")

local M = {}

local function flags(popup, b)
  if vim.tbl_contains(popup:get_arguments(), "--skip-emptied") then b = b.skip_emptied end
  return b
end

function M.rebase_revision(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Rebase revision", cwd = root })
  if not rev then return end
  local dest = finder.pick_revision({ prompt = "Onto destination", cwd = root })
  if dest then common.run(popup, flags(popup, cli.rebase.revision(rev).destination(dest))) end
end

function M.rebase_source(popup)
  local root = common.root(popup)
  local src = common.commit(popup) or finder.pick_revision({ prompt = "Rebase source", cwd = root })
  if not src then return end
  local dest = finder.pick_revision({ prompt = "Onto destination", cwd = root })
  if dest then common.run(popup, flags(popup, cli.rebase.source(src).destination(dest))) end
end

function M.rebase_destination(popup) M.rebase_revision(popup) end

function M.rebase_bookmark(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Rebase bookmark", cwd = root })
  if not bm then return end
  local dest = finder.pick_revision({ prompt = "Onto destination", cwd = root })
  if dest then common.run(popup, flags(popup, cli.rebase.branch(bm).destination(dest))) end
end

return M
