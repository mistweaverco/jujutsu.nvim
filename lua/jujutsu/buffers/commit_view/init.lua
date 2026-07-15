local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

local SEP, REC = "\x1f", "\x1e"

local function field_template(fields)
  local parts = {}
  for i, f in ipairs(fields) do
    if i > 1 then
      table.insert(parts, string.format('"\\x1f" ++ %s', f))
    else
      table.insert(parts, f)
    end
  end
  return table.concat(parts, " ++ ") .. ' ++ "\\x1e" ++ description ++ "\\n"'
end

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

---@param root string
---@param rev string
---@return table info, string[] diff_lines
local function fetch(root, rev)
  local tmpl = field_template({
    "change_id",
    "commit_id",
    "author.name()",
    "author.email()",
    "author.timestamp()",
    'bookmarks.join(",")',
    'if(conflict, "true", "false")',
    'if(empty, "true", "false")',
  })

  local meta = cli.log.revisions(rev).no_graph.template(tmpl).limit(1).call({
    cwd = root,
    hidden = true,
    trim = false,
  })

  local info = {
    change_id = rev,
    commit_id = "",
    author_name = "",
    author_email = "",
    author_date = "",
    bookmarks = {},
    conflict = false,
    empty = false,
    description = { "(no description)" },
  }

  local text = table.concat(meta.stdout, "\n")
  local rec_end = text:find(REC, 1, true)
  if rec_end then
    local fields = vim.split(text:sub(1, rec_end - 1):gsub("\n", ""), SEP, { plain = true })
    info.change_id = fields[1] or rev
    info.commit_id = fields[2] or ""
    info.author_name = fields[3] or ""
    info.author_email = fields[4] or ""
    info.author_date = fields[5] or ""
    if fields[6] and fields[6] ~= "" then info.bookmarks = vim.split(fields[6], ",", { plain = true }) end
    info.conflict = fields[7] == "true"
    info.empty = fields[8] == "true"

    local desc = vim.trim(text:sub(rec_end + 1))
    if desc ~= "" then
      info.description = vim.split(desc, "\n", { plain = true })
      while #info.description > 0 and info.description[#info.description] == "" do
        table.remove(info.description)
      end
    end
  end

  -- Git-format patch only (avoid jj show's unstyled preamble)
  local diff = cli.diff.revision(rev).git.call({ cwd = root, hidden = true, remove_ansi = true })
  if diff.code ~= 0 or #diff.stdout == 0 then
    local show = cli.show.git.args(rev).call({ cwd = root, hidden = true, remove_ansi = true })
    local patch = {}
    local in_patch = false
    for _, line in ipairs(show.stdout) do
      if line:match("^diff %-%-git") then in_patch = true end
      if in_patch then table.insert(patch, line) end
    end
    return info, patch
  end

  return info, diff.stdout or {}
end

---@param info table
---@param diff_lines string[]
---@return string[], table[]
local function build_render(info, diff_lines)
  local lines = {}
  local highlights = {}

  local function add_line(text, opts)
    opts = opts or {}
    table.insert(lines, text)
    local row = #lines - 1
    if opts.line_hl then table.insert(highlights, { line = row, line_hl = opts.line_hl }) end
    for _, h in ipairs(opts.parts or {}) do
      table.insert(highlights, {
        line = row,
        col = h.col,
        end_col = h.end_col,
        hl = h.hl,
      })
    end
  end

  local function labeled(label, value, value_hl)
    local text = label .. value
    add_line(text, {
      parts = {
        { col = 0, end_col = #label, hl = "JujutsuSubtle" },
        { col = #label, end_col = #text, hl = value_hl or "Normal" },
      },
    })
  end

  -- Header banner
  local header = "Change " .. (info.change_id:sub(1, 12))
  add_line(header, { line_hl = "JujutsuCommitHeader" })

  labeled("Commit ID: ", info.commit_id, "JujutsuCommitId")
  labeled("Author:    ", string.format("%s <%s>", info.author_name, info.author_email), "JujutsuDescription")
  labeled("Date:      ", info.author_date, "Normal")

  if #info.bookmarks > 0 then labeled("Bookmarks: ", table.concat(info.bookmarks, ", "), "JujutsuBranch") end

  local status = {}
  if info.empty then table.insert(status, "empty") end
  if info.conflict then table.insert(status, "conflict") end
  if #status > 0 then
    labeled("Status:    ", table.concat(status, ", "), info.conflict and "JujutsuConflict" or "JujutsuSubtle")
  end

  add_line("")

  for _, d in ipairs(info.description) do
    add_line(d, {
      parts = { { col = 0, end_col = #d, hl = "JujutsuDescription" } },
    })
  end

  add_line("")

  if #diff_lines == 0 then
    add_line("(no changes)", {
      parts = { { col = 0, end_col = #"(no changes)", hl = "JujutsuSubtle" } },
    })
  else
    for _, dline in ipairs(diff_lines) do
      add_line(dline, { line_hl = diff_line_hl(dline) })
    end
  end

  return lines, highlights
end

---@param root string
---@param rev string
function M.open(root, rev)
  require("jujutsu.hl").setup()

  local info, diff_lines = fetch(root, rev)
  local lines, highlights = build_render(info, diff_lines)

  local buf = Buffer.create("jujutsu://commit/" .. rev, "jujutsu-commit")
  Buffer.open(buf, config.values.commit_view.kind or "vsplit")
  Buffer.render(buf, lines, highlights)

  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
  vim.keymap.set("n", "<esc>", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

return M
