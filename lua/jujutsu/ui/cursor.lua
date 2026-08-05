local M = {}

---Vertical bar while typing in jujutsu floats (picker/input/comment prompt).
local TYPING_GUICURSOR = "n:ver25,i:ver25-blink,r:hor20,o:hor50"

---@type string|nil
local saved_guicursor = nil
---@type integer
local depth = 0

---Use a vertical-bar cursor for the next float(s). Nested floats share one override.
function M.push_typing()
  depth = depth + 1
  if depth == 1 then
    saved_guicursor = vim.o.guicursor
    vim.o.guicursor = TYPING_GUICURSOR
  end
end

---Restore the user's cursor after the last typing float closes.
function M.pop_typing()
  if depth <= 0 then return end
  depth = depth - 1
  if depth == 0 and saved_guicursor ~= nil then
    vim.o.guicursor = saved_guicursor
    saved_guicursor = nil
  end
end

return M
