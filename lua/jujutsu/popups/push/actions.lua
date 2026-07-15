local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")

local M = {}

local function apply_flags(popup, b)
  local args = popup:get_arguments()
  if vim.tbl_contains(args, "--deleted") then b = b.deleted end
  if vim.tbl_contains(args, "--dry-run") then b = b.dry_run end
  if vim.tbl_contains(args, "--all") then b = b.all end
  return b
end

function M.push(popup) common.run(popup, apply_flags(popup, cli.git_push)) end

function M.push_bookmark(popup)
  local root = common.root(popup)
  local bm = finder.pick_bookmark({ prompt = "Push bookmark", cwd = root })
  if bm then common.run(popup, apply_flags(popup, cli.git_push.bookmark(bm))) end
end

function M.push_change(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Push change", cwd = root })
  if rev then common.run(popup, apply_flags(popup, cli.git_push.change(rev))) end
end

return M
