local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")

local M = {}

function M.fetch(popup)
  local args = popup:get_arguments()
  local b = cli.git_fetch
  if vim.tbl_contains(args, "--all-remotes") then b = b.all_remotes end
  common.run(popup, b)
end

function M.fetch_remote(popup)
  local root = common.root(popup)
  local remote = finder.pick_remote({ prompt = "Fetch remote", cwd = root })
  if remote then common.run(popup, cli.git_fetch.remote(remote)) end
end

return M
