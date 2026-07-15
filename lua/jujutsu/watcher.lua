local config = require("jujutsu.config")

---@class Watcher
---@field handle uv.uv_fs_event_t|nil
---@field root string
---@field callback fun()
---@field timer uv.uv_timer_t|nil

local M = {}

---@type Watcher|nil
local active

local function stop_handle()
  if not active then return end
  if active.timer then
    active.timer:stop()
    active.timer:close()
    active.timer = nil
  end
  if active.handle then
    active.handle:stop()
    active.handle:close()
    active.handle = nil
  end
end

---@param root string
---@param callback fun()
function M.start(root, callback)
  if not config.values.filewatcher.enabled then return end
  M.stop()
  local path = root .. "/.jj"
  if not vim.uv.fs_stat(path) then return end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  active = {
    handle = handle,
    root = root,
    callback = callback,
  }

  local debounce_ms = 200
  handle:start(path, { recursive = true }, function(err)
    if err or not active then return end
    if active.timer then
      active.timer:stop()
    else
      active.timer = vim.uv.new_timer()
    end
    active.timer:start(debounce_ms, 0, function()
      vim.schedule(function()
        if active and active.callback then active.callback() end
      end)
    end)
  end)
end

function M.stop()
  stop_handle()
  active = nil
end

return M
