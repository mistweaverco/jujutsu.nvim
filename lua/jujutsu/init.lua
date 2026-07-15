local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local notify = require("jujutsu.notify")
local repository = require("jujutsu.jj.repository")

local M = {}
local did_setup = false

---@param opts? table
function M.setup(opts)
  if vim.fn.has("nvim-0.10") ~= 1 then
    notify.error("jujutsu.nvim requires Neovim 0.10+")
    return
  end
  if did_setup then
    config.setup(opts)
    return
  end
  did_setup = true
  config.setup(opts)
  require("jujutsu.hl").setup()
  require("jujutsu.hl").attach_autocmd()
  M.autocmd_group = vim.api.nvim_create_augroup("Jujutsu", { clear = false })
end

local function ensure_setup()
  if not did_setup then M.setup({}) end
end

local function construct_opts(opts)
  opts = opts or {}
  if opts.cwd and not opts.no_expand then opts.cwd = vim.fn.expand(opts.cwd) end
  opts.cwd = opts.cwd or vim.fn.getcwd()
  opts._workspace_root = cli.find_workspace_root(opts.cwd)
  return opts
end

local popup_names = {
  bookmark = true,
  change = true,
  commit = true, -- alias for change
  diff = true,
  fetch = true,
  help = true,
  log = true,
  push = true,
  rebase = true,
  remote = true,
  squash = true,
  undo = true,
  workspace = true,
}

---@class OpenOpts
---@field cwd? string
---@field kind? string
---@field [1]? string popup name

---@param opts? OpenOpts
function M.open(opts)
  ensure_setup()
  opts = construct_opts(opts)

  if not opts._workspace_root then
    notify.error(("`%s` is not a jj workspace"):format(opts.cwd))
    return
  end

  repository.instance(opts.cwd)

  if opts[1] ~= nil then
    local name = opts[1]
    if name == "commit" then name = "change" end
    if not popup_names[name] then
      notify.error("Invalid popup: " .. tostring(opts[1]))
      return
    end
    -- Open status first if needed, then popup
    local status = require("jujutsu.buffers.status")
    if not status.instance() then status.open(opts._workspace_root, opts.cwd, opts) end
    require("jujutsu.popups." .. name).create({
      root = opts._workspace_root,
    })
    return
  end

  require("jujutsu.buffers.status").open(opts._workspace_root, opts.cwd, opts)
end

function M.close()
  local status = require("jujutsu.buffers.status")
  status.close()
end

function M.refresh()
  local status = require("jujutsu.buffers.status")
  if status.instance() then status.refresh() end
end

function M.focus()
  local status = require("jujutsu.buffers.status")
  status.focus()
end

---Create a bindable action for custom user keymaps.
---@param popup string
---@param action string
---@param args? string[]
---@return function
function M.action(popup, action, args)
  args = args or {}
  return function()
    ensure_setup()
    local ok, actions = pcall(require, "jujutsu.popups." .. popup .. ".actions")
    if not ok then
      notify.error("Invalid popup: " .. popup)
      return
    end
    local fn = actions[action]
    if not fn then
      notify.error(("Invalid action %s for %s"):format(action, popup))
      return
    end
    local async = require("jujutsu.async")
    async.void(function()
      fn({
        close = function() end,
        state = { env = {} },
        get_arguments = function() return args end,
        get_internal_arguments = function() return {} end,
      })
      vim.schedule(function() M.refresh() end)
    end)
  end
end

function M.get_config() return config.values end

M.config = config
M.cli = cli

return M
