local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")

local M = {}

---@param root string
function M.open(root)
  local res = cli.op_log.limit(50).call({ cwd = root, hidden = true, remove_ansi = false })
  local buf = Buffer.create("jujutsu://op-log", "jujutsu-log")
  Buffer.open(buf, "tab")
  Buffer.render(buf, res.stdout)
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

return M
