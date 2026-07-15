local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")

local M = {}

local function show_diff(lines, title)
  local buf = Buffer.create("jujutsu://diff/" .. (title or "diff"), "diff")
  Buffer.open(buf, "tab")
  Buffer.render(buf, lines)
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

function M.working_copy(popup)
  local root = common.root(popup)
  local res = cli.diff.call({ cwd = root, hidden = true, remove_ansi = false })
  show_diff(res.stdout, "wc")
end

function M.change(popup)
  local root = common.root(popup)
  local rev = common.commit(popup) or finder.pick_revision({ prompt = "Diff change", cwd = root })
  if rev then
    local res = cli.diff.revision(rev).call({ cwd = root, hidden = true, remove_ansi = false })
    show_diff(res.stdout, rev)
  end
end

function M.range(popup)
  local root = common.root(popup)
  local from = finder.pick_revision({ prompt = "Diff from", cwd = root })
  if not from then return end
  local to = finder.pick_revision({ prompt = "Diff to", cwd = root })
  if not to then return end
  local res = cli.diff.from(from).to(to).call({ cwd = root, hidden = true, remove_ansi = false })
  show_diff(res.stdout, from .. ".." .. to)
end

function M.trunk(popup)
  local root = common.root(popup)
  local res = cli.diff.from("trunk()").to("@").call({
    cwd = root,
    hidden = true,
    remove_ansi = false,
    on_error = function() return false end,
  })
  if res.code ~= 0 then
    res = cli.diff.from("main").to("@").call({
      cwd = root,
      hidden = true,
      remove_ansi = false,
      on_error = function() return false end,
    })
  end
  if res.code ~= 0 then
    res = cli.diff.from("master").to("@").call({ cwd = root, hidden = true, remove_ansi = false })
  end
  show_diff(res.stdout, "trunk")
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
