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
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Diff change", cwd = root })
  if not rev then return end
  DiffBuffer.open({
    cwd = root,
    title = rev,
    builder = cli.diff.revision(rev),
  })
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
    builder = cli.diff.from(from).to(to),
  })
end

function M.trunk(popup)
  local root = common.root(popup)
  local builders = {
    { title = "trunk", builder = cli.diff.from("trunk()").to("@") },
    { title = "main", builder = cli.diff.from("main").to("@") },
    { title = "master", builder = cli.diff.from("master").to("@") },
  }
  for _, entry in ipairs(builders) do
    local res = entry.builder.git.call({
      cwd = root,
      hidden = true,
      remove_ansi = true,
      on_error = function() return false end,
    })
    if res.code == 0 then
      DiffBuffer.show(res.stdout, entry.title)
      return
    end
  end
  DiffBuffer.show({ "(could not diff against trunk/main/master)" }, "trunk")
end

function M.diffedit(popup)
  local rev = common.commit(popup) or "@"
  common.run(popup, cli.diffedit.revision(rev))
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
