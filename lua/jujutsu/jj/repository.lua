local cli = require("jujutsu.jj.cli")

local M = {
  ---@type { root: string, cwd: string }|nil
  current = nil,
}

---@param cwd? string
---@return { root: string, cwd: string }|nil
function M.instance(cwd)
  cwd = cwd or vim.fn.getcwd()
  local root = cli.find_workspace_root(cwd)
  if not root then return nil end
  M.current = { root = root, cwd = cwd }
  return M.current
end

---@return string|nil
function M.root() return M.current and M.current.root end

return M
