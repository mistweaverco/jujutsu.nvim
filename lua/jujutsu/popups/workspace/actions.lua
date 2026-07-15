local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")
local notify = require("jujutsu.notify")

local M = {}

function M.add(popup)
  vim.ui.input({ prompt = "Workspace path: " }, function(path)
    if not path or path == "" then return end
    path = vim.fn.expand(path)
    local b = cli.workspace_add.args(path)
    common.run(popup, b)
    local cmd = config.values.workspace_open_command
    if cmd then vim.fn.system(cmd:gsub("{path}", path)) end
  end)
end

function M.quick_add(popup)
  local root = common.root(popup)
  local base = vim.fn.expand(config.values.workspace_worktrees_directory or "~/.worktrees")
  vim.fn.mkdir(base, "p")
  vim.ui.input({ prompt = "Workspace name: " }, function(name)
    if not name or name == "" then return end
    local path = base .. "/" .. name
    local init = config.values.workspace_initialize_command
    if init then vim.fn.system(init:gsub("{path}", path)) end
    cli.workspace_add.name(name).args(path).call({ cwd = root, hidden = false })
    notify.info("Added workspace " .. path)
    local cmd = config.values.workspace_open_command
    if cmd then vim.fn.system(cmd:gsub("{path}", path)) end
    require("jujutsu").refresh()
  end)
end

function M.forget(popup)
  local root = common.root(popup)
  local res = cli.workspace_list.call({ cwd = root, hidden = true })
  local selected = finder.pick({ prompt = "Forget workspace", entries = res.stdout })
  if selected then
    local name = vim.split(selected, "%s+")[1]
    common.run(popup, cli.workspace_forget.args(name))
  end
end

function M.rename(popup)
  local root = common.root(popup)
  local res = cli.workspace_list.call({ cwd = root, hidden = true })
  local selected = finder.pick({ prompt = "Rename workspace", entries = res.stdout })
  if not selected then return end
  local old = vim.split(selected, "%s+")[1]
  vim.ui.input({ prompt = "New name: ", default = old }, function(name)
    if name and name ~= "" then
      cli.workspace_rename.args(old, name).call({ cwd = root, hidden = false })
      require("jujutsu").refresh()
    end
  end)
end

function M.list(popup)
  local root = common.root(popup)
  local res = cli.workspace_list.call({ cwd = root, hidden = true })
  local buf = Buffer.create("jujutsu://workspaces", "jujutsu-log")
  Buffer.open(buf, "split")
  Buffer.render(buf, #res.stdout > 0 and res.stdout or { "(no workspaces)" })
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

function M.update_stale(popup) common.run(popup, cli.workspace_update_stale) end

return M
