local Buffer = require("jujutsu.ui.buffer")

local M = {}

---@param line string
---@return string
local function diff_line_hl(line)
  local first = line:sub(1, 1)
  if line:match("^@@") then
    return "JujutsuHunkHeader"
  elseif line:match("^diff ") or line:match("^index ") or line:match("^%-%-%-") or line:match("^%+%+%+") then
    return "JujutsuDiffHeader"
  elseif first == "+" then
    return "JujutsuDiffAdd"
  elseif first == "-" then
    return "JujutsuDiffDelete"
  end
  return "JujutsuDiffContext"
end

---@param builder any jj cli builder for `jj diff`
---@param opts { cwd: string, title?: string }
---@return ProcessResult
local function run_git_diff(builder, opts)
  -- Prefer git format so lines start with +/-/@@ (needed for coloring)
  return builder.git.call({
    cwd = opts.cwd,
    hidden = true,
    remove_ansi = true,
  })
end

---@param lines string[]
---@param title? string
function M.show(lines, title)
  if #lines == 0 then lines = { "(no changes)" } end

  local highlights = {}
  for i, line in ipairs(lines) do
    table.insert(highlights, {
      line = i - 1,
      line_hl = (#lines == 1 and line == "(no changes)") and "JujutsuSubtle" or diff_line_hl(line),
    })
  end

  local buf = Buffer.create("jujutsu://diff/" .. (title or "diff"), "jujutsu-diff")
  Buffer.open(buf, "tab")
  Buffer.render(buf, lines, highlights)
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

---@param opts { cwd: string, title?: string, builder: any }
function M.open(opts)
  local res = run_git_diff(opts.builder, opts)
  M.show(res.stdout, opts.title)
end

M.diff_line_hl = diff_line_hl

return M
