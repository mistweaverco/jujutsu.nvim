local notify = require("jujutsu.notify")

local M = {}

function M.open()
  local ok, codediff = pcall(require, "codediff")
  if not ok then
    notify.error("codediff.nvim is not installed")
    return
  end
  if codediff.open then
    codediff.open()
  elseif codediff.diff then
    codediff.diff()
  else
    notify.warn("codediff.nvim API not recognized; open manually")
  end
end

return M
