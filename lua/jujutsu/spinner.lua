local config = require("jujutsu.config")

local M = {}

local NOTIFY_ID = "jujutsu-spinner"
local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local active = false
local frame = 1
local message = ""

local function tick()
  if not active then return end
  local icon = config.values.notification_icon or "󰊢"
  vim.notify(string.format("%s %s %s", icon, FRAMES[frame], message), vim.log.levels.INFO, {
    title = "jujutsu",
    id = NOTIFY_ID,
    replace = true,
    hide_from_history = true,
  })
  frame = frame % #FRAMES + 1
  vim.defer_fn(tick, 80)
end

---@param msg? string
function M.start(msg)
  if config.values.process_spinner == false then return end
  M.stop()
  active = true
  frame = 1
  message = msg or "Running…"
  tick()
end

function M.stop()
  if not active then return end
  active = false
  pcall(vim.notify, nil, vim.log.levels.INFO, { id = NOTIFY_ID, replace = true, hide_from_history = true })
end

return M
