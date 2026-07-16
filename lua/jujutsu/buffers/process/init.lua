local Buffer = require("jujutsu.ui.buffer")
local config = require("jujutsu.config")
local history = require("jujutsu.history")

local M = {}

function M.show_history()
  local entries = history.list()
  local lines = { "Command history", "" }
  for i, e in ipairs(entries) do
    table.insert(lines, string.format("%d. [%d] %.2fs  %s", i, e.code, e.time, e.cmd))
    for _, l in ipairs(e.stderr) do
      table.insert(lines, "    " .. l)
    end
  end
  if #entries == 0 then table.insert(lines, "(empty)") end

  local buf = Buffer.create("jujutsu://history", "jujutsu-log")
  Buffer.open(buf, "split")
  Buffer.render(buf, lines)
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

---@param res ProcessResult
function M.show_result(res)
  if not config.values.auto_show_console then return end

  local status = res.code == 0 and "ok" or "failed"
  local lines = {
    res.cmd,
    string.format("exit=%d time=%.2fs (%s)", res.code, res.time, status),
    "",
  }
  vim.list_extend(lines, res.stdout)
  if #res.stderr > 0 then
    table.insert(lines, "--- stderr ---")
    vim.list_extend(lines, res.stderr)
  end
  if #res.stdout == 0 and #res.stderr == 0 then table.insert(lines, "(no output)") end

  local buf = Buffer.create("jujutsu://process", "jujutsu-log")
  Buffer.open(buf, "split")
  Buffer.render(buf, lines)
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })

  if res.code == 0 and config.values.auto_close_console then
    local ms = config.values.console_timeout or 2000
    vim.defer_fn(function()
      if Buffer.is_open(buf) then Buffer.close(buf) end
    end, ms)
  end
end

return M
