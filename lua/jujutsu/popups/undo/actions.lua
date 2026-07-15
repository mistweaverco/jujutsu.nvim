local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")

local M = {}

function M.undo(popup) common.run(popup, cli.undo) end

function M.redo(popup) common.run(popup, cli.redo) end

function M.op_log(popup)
  local root = common.root(popup)
  local res = cli.op_log.limit(30).call({ cwd = root, hidden = true, remove_ansi = false })
  local buf = Buffer.create("jujutsu://op-log", "jujutsu-log")
  Buffer.open(buf, "tab")
  Buffer.render(buf, res.stdout)
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

function M.op_restore(popup)
  local root = common.root(popup)
  local tmpl = 'op_id.short(12) ++ " " ++ description.first_line() ++ "\\n"'
  local res = cli.op_log.no_graph.template(tmpl).limit(40).call({
    cwd = root,
    hidden = true,
  })
  local entries = {}
  for _, line in ipairs(res.stdout) do
    if line ~= "" then table.insert(entries, line) end
  end
  local selected = finder.pick({ prompt = "restore operation", entries = entries })
  if selected then
    local id = vim.split(selected, "%s+")[1]
    common.run(popup, cli.op_restore.args(id))
  end
end

return M
