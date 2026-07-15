local M = {}

local icon = function()
  local ok, config = pcall(require, "jujutsu.config")
  if ok and config.values and config.values.notification_icon then return config.values.notification_icon end
  return "󰊢"
end

---@param msg string
---@param level integer
local function notify(msg, level) vim.notify(msg, level, { title = "jujutsu", icon = icon() }) end

function M.info(msg) notify(msg, vim.log.levels.INFO) end

function M.warn(msg) notify(msg, vim.log.levels.WARN) end

function M.error(msg) notify(msg, vim.log.levels.ERROR) end

function M.debug(msg) notify(msg, vim.log.levels.DEBUG) end

return M
