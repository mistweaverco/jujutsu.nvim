local config = require("jujutsu.config")

---@class Watcher
---@field handle uv.uv_fs_event_t|nil
---@field root string
---@field callback fun()
---@field timer uv.uv_timer_t|nil
---@field name string

local M = {}

---@type table<string, Watcher>
local active = {}

---@param name string
local function stop_handle(name)
  local w = active[name]
  if not w then return end
  if w.timer then
    w.timer:stop()
    w.timer:close()
    w.timer = nil
  end
  if w.handle then
    w.handle:stop()
    w.handle:close()
    w.handle = nil
  end
end

---Start a named fs watcher on `{root}/.jj`. Multiple names may watch the same root.
---@param root string
---@param callback fun()
---@param name? string defaults to "default" (status buffer)
function M.start(root, callback, name)
  name = name or "default"
  if not config.values.filewatcher.enabled then return end
  M.stop(name)
  local path = root .. "/.jj"
  if not vim.uv.fs_stat(path) then return end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  local w = {
    handle = handle,
    root = root,
    callback = callback,
    name = name,
  }
  active[name] = w

  local debounce_ms = 200
  handle:start(path, { recursive = true }, function(err)
    if err or not active[name] then return end
    local cur = active[name]
    if cur.timer then
      cur.timer:stop()
    else
      cur.timer = vim.uv.new_timer()
    end
    cur.timer:start(debounce_ms, 0, function()
      vim.schedule(function()
        local live = active[name]
        if live and live.callback then live.callback() end
      end)
    end)
  end)
end

---@param name? string defaults to "default"
function M.stop(name)
  name = name or "default"
  stop_handle(name)
  active[name] = nil
end

function M.stop_all()
  for name in pairs(active) do
    M.stop(name)
  end
end

return M
