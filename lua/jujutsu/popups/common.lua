local M = {}

---@return string
function M.root(popup)
  if popup and popup.state and popup.state.env and popup.state.env.root then return popup.state.env.root end
  local repo = require("jujutsu.jj.repository")
  return repo.root() or vim.fn.getcwd()
end

---@param popup table
---@return string|nil
function M.commit(popup)
  local env = popup.state.env or {}
  return env.commit or (env.change and env.change.change_id) or nil
end

---@param popup table
---@param builder any cli builder that supports call_async
function M.run(popup, builder)
  local res = builder.call_async({ cwd = M.root(popup), hidden = false })
  return res
end

return M
