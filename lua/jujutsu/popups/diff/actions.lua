local DiffBuffer = require("jujutsu.buffers.diff")
local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")

local M = {}

function M.working_copy(popup)
  local root = common.root(popup)
  DiffBuffer.open({
    cwd = root,
    title = "wc",
    builder = cli.diff,
  })
end

function M.change(popup)
  local root = common.root(popup)
  local rev = common.commit(popup)
  local path = common.path(popup)
  require("jujutsu.buffers.file_history").open(root, { revision = rev, path = path })
end

function M.range(popup)
  local root = common.root(popup)
  local from = finder.pick_revision({ prompt = "Diff from", cwd = root })
  if not from then return end
  local to = finder.pick_revision({ prompt = "Diff to", cwd = root })
  if not to then return end
  DiffBuffer.open({
    cwd = root,
    title = from .. ".." .. to,
    left = from,
    right = to,
    builder = cli.diff.from(from).to(to),
  })
end

function M.trunk(popup)
  local root = common.root(popup)
  local candidates = {
    { title = "trunk", left = "trunk()" },
    { title = "main", left = "main" },
    { title = "master", left = "master" },
  }
  for _, entry in ipairs(candidates) do
    local res = cli.diff.from(entry.left).to("@").summary.call({
      cwd = root,
      hidden = true,
      remove_ansi = true,
      on_error = function() return false end,
    })
    if res.code == 0 then
      DiffBuffer.open({
        cwd = root,
        title = entry.title,
        left = entry.left,
        right = "@",
        builder = cli.diff.from(entry.left).to("@"),
      })
      return
    end
  end
  require("jujutsu.notify").warn("could not diff against trunk/main/master")
end

function M.diffedit(popup)
  local rev = common.commit(popup) or "@"
  common.run_interactive(popup, cli.diffedit.revision(rev), { title = " jj diffedit " })
end

function M.external(popup)
  local root = common.root(popup)
  local viewer = config.values.diff_viewer
  if not viewer then
    if config.check_integration("diffview") then
      viewer = "diffview"
    elseif config.check_integration("codediff") then
      viewer = "codediff"
    end
  end
  if viewer == "diffview" then
    require("jujutsu.integrations.diffview").open(root)
  elseif viewer == "codediff" then
    require("jujutsu.integrations.codediff").open(root)
  else
    M.working_copy(popup)
  end
end

return M
