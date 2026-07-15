local M = {}

---@type string|nil
local cached_binary

---@return string
function M.resolve_jj()
  local config = require("jujutsu.config")
  local bin = config.values.jj_binary
  if bin and bin ~= "auto" then return bin end
  if cached_binary then return cached_binary end
  local found = vim.fn.exepath("jj")
  if found == "" then found = "jj" end
  cached_binary = found
  return found
end

function M.clear_cache() cached_binary = nil end

return M
