local notify = require("jujutsu.notify")

local M = {}

---Open diffview for the jj colocated git repo if available.
---@param root string
function M.open(root)
  local ok, diffview = pcall(require, "diffview")
  if not ok then
    notify.error("diffview.nvim is not installed")
    return
  end
  -- Prefer opening from colocated .git
  local git = root .. "/.git"
  if vim.uv.fs_stat(git) then
    vim.cmd("DiffviewOpen")
  else
    notify.warn("diffview requires a git-colocated jj repository")
    pcall(function() diffview.open({}) end)
  end
end

return M
