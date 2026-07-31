local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

local SEP = "\x1f"

local ANNOTATE_TEMPLATE = table.concat({
  "commit.change_id().shortest(8)",
  "commit.author().name()",
  'commit_timestamp(commit).local().format("%Y-%m-%d")',
  "line_number",
  'if(first_line_in_hunk, "1", "0")',
  "commit.description().first_line()",
  "content",
}, ' ++ "\\x1f" ++ ')

---@class AnnotateLine
---@field change_id string
---@field author string
---@field date string
---@field line_number integer
---@field first_hunk boolean
---@field description string
---@field content string

---@class AnnotateView
---@field buf Buffer
---@field win integer|nil
---@field root string
---@field path string
---@field lines AnnotateLine[]
---@field selected_change string|nil
---@field focus_line integer|nil

---@param root string
---@param path string
---@param revision? string
---@return AnnotateLine[], string|nil err
function M.fetch(root, path, revision)
  local builder = cli.file_annotate.template(ANNOTATE_TEMPLATE).paths(path)
  if revision and revision ~= "" then builder = builder.revision(revision) end
  local res = builder.call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if res.code ~= 0 then
    local err = table.concat(res.stderr or {}, "\n")
    if err == "" then err = "jj file annotate failed" end
    return {}, err
  end

  ---@type AnnotateLine[]
  local lines = {}
  for _, raw in ipairs(res.stdout or {}) do
    if raw ~= "" then
      local parts = vim.split(raw, SEP, { plain = true })
      if #parts >= 7 then
        local content = table.concat(parts, SEP, 7)
        content = content:gsub("\r?\n$", "")
        lines[#lines + 1] = {
          change_id = parts[1] or "",
          author = parts[2] or "",
          date = parts[3] or "",
          line_number = tonumber(parts[4]) or (#lines + 1),
          first_hunk = parts[5] == "1",
          description = parts[6] or "",
          content = content,
        }
      end
    end
  end
  return lines, nil
end

---@param root string
---@param win integer
---@param path string
---@return AnnotateView
function M.create(root, win, path)
  local buf = Buffer.create("jujutsu://annotate/" .. path, "jujutsu-annotate")
  vim.api.nvim_win_set_buf(win, buf.bufnr)
  buf.winid = win
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  if config.values.disable_line_numbers then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end

  return {
    buf = buf,
    win = win,
    root = root,
    path = path,
    lines = {},
    selected_change = nil,
    focus_line = nil,
  }
end

---@param view AnnotateView
function M.render(view)
  local lines = {}
  local highlights = {}

  local id_w, author_w, date_w = 8, 8, 10
  for _, row in ipairs(view.lines) do
    id_w = math.max(id_w, #row.change_id)
    author_w = math.max(author_w, math.min(#row.author, 16))
    date_w = math.max(date_w, #row.date)
  end
  author_w = math.min(author_w, 16)

  for i, row in ipairs(view.lines) do
    local author = row.author
    if #author > author_w then author = author:sub(1, author_w - 1) .. "…" end
    local meta =
      string.format("%-" .. id_w .. "s  %-" .. author_w .. "s  %-" .. date_w .. "s", row.change_id, author, row.date)
    local text = meta .. " │ " .. row.content
    lines[#lines + 1] = text

    local col = 0
    local function push_hl(len, hl)
      if len > 0 and hl then
        highlights[#highlights + 1] = {
          line = i - 1,
          col = col,
          end_col = col + len,
          hl = hl,
        }
      end
      col = col + math.max(len, 0)
    end

    push_hl(#row.change_id, "JujutsuAnnotateHash")
    push_hl(id_w - #row.change_id + 2, nil) -- pad + spaces
    push_hl(#author, "JujutsuAnnotateAuthor")
    push_hl(author_w - #author + 2, nil)
    push_hl(#row.date, "JujutsuAnnotateDate")
    push_hl(date_w - #row.date, nil)
    push_hl(3, "JujutsuSubtle") -- " │ "

    local line_hl = nil
    if view.focus_line and row.line_number == view.focus_line then
      line_hl = "JujutsuAnnotateCurrent"
    elseif view.selected_change and row.change_id == view.selected_change then
      line_hl = "JujutsuAnnotateSelected"
    end
    if line_hl then highlights[#highlights + 1] = {
      line = i - 1,
      line_hl = line_hl,
    } end
  end

  if #lines == 0 then
    lines = { "(no annotate data)" }
    highlights = { { line = 0, col = 0, end_col = #"(no annotate data)", hl = "JujutsuSubtle" } }
  end

  Buffer.render(view.buf, lines, highlights)
end

---@param view AnnotateView
---@param line_number integer
function M.goto_line(view, line_number)
  if not view.win or not vim.api.nvim_win_is_valid(view.win) then return end
  for i, row in ipairs(view.lines) do
    if row.line_number == line_number then
      vim.api.nvim_win_set_cursor(view.win, { i, 0 })
      return
    end
  end
  if line_number >= 1 and line_number <= #view.lines then vim.api.nvim_win_set_cursor(view.win, { line_number, 0 }) end
end

---@param view AnnotateView
---@param change_id string|nil
function M.highlight_change(view, change_id)
  view.selected_change = change_id
  M.render(view)
  if not change_id or change_id == "" then return end
  for i, row in ipairs(view.lines) do
    if row.change_id == change_id or change_id:sub(1, #row.change_id) == row.change_id then
      if view.win and vim.api.nvim_win_is_valid(view.win) then vim.api.nvim_win_set_cursor(view.win, { i, 0 }) end
      return
    end
  end
end

---@param view AnnotateView
function M.focus(view)
  if view.win and vim.api.nvim_win_is_valid(view.win) then vim.api.nvim_set_current_win(view.win) end
end

---@param view AnnotateView
function M.destroy(view)
  if not view then return end
  if view.buf and vim.api.nvim_buf_is_valid(view.buf.bufnr) then
    pcall(vim.api.nvim_buf_delete, view.buf.bufnr, { force = true })
  end
end

return M
