local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")

local M = {}

local function flags(popup, b)
  local args = popup:get_arguments()
  if vim.tbl_contains(args, "--keep-emptied") then b = b.keep_emptied end
  if vim.tbl_contains(args, "--use-destination-message") then b = b.use_destination_message end
  return b
end

function M.squash_parent(popup)
  local rev = common.commit(popup) or "@"
  common.run(popup, flags(popup, cli.squash.revision(rev)))
end

function M.squash_into(popup)
  local root = common.root(popup)
  local into = finder.pick_revision({ prompt = "Squash into", cwd = root })
  if into then common.run(popup, flags(popup, cli.squash.into(into))) end
end

function M.squash_from(popup)
  local root = common.root(popup)
  local from = common.commit(popup) or finder.pick_revision({ prompt = "Squash from", cwd = root })
  if not from then return end
  local into = finder.pick_revision({ prompt = "Squash into", cwd = root })
  if into then common.run(popup, flags(popup, cli.squash.from(from).into(into))) end
end

return M
