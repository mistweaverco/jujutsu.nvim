local M = {}

---@param root string
---@param rev string
function M.open(root, rev)
  require("jujutsu.hl").setup()
  require("jujutsu.buffers.diff").open({
    cwd = root,
    revision = rev,
    title = rev,
  })
end

return M
