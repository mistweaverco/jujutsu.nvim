local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local status_data = require("jujutsu.jj.status")

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
  return table.concat(parts, " ++ ") .. ' ++ "\\x1e"'
end

---@class FileHistoryEntry
---@field change_id string
---@field commit_id string
---@field bookmarks string[]
---@field description string
---@field author string
---@field ago string
---@field conflict boolean
---@field empty boolean
---@field working_copy boolean
---@field files? { path: string, status: string }[]
---@field open boolean

---@class FileHistoryPanel
---@field buf Buffer
---@field win integer|nil
---@field root string
---@field path? string  -- when set, history is scoped to this path (single-file mode)
---@field entries FileHistoryEntry[]
-- luacheck: ignore
---@field line_map table<integer, { kind: "change"|"file"|"header"|"empty", entry?: FileHistoryEntry, file?: { path: string, status: string }, index?: integer }>
---@field selected_change string|nil
---@field selected_path string|nil

---@param root string
---@param limit integer
---@param path? string
---@return FileHistoryEntry[]
function M.load_entries(root, limit, path)
  local tmpl = field_template({
    "change_id.short(8)",
    "commit_id.short(8)",
    'bookmarks.join(",")',
    "description.first_line()",
    "author.name()",
    "author.timestamp().ago()",
    'if(conflict, "true", "false")',
    'if(empty, "true", "false")',
    'if(current_working_copy, "true", "false")',
  })

  local builder = cli.log.revisions("all()").no_graph.template(tmpl).limit(limit)
  if path and path ~= "" then builder = builder.paths(path) end
  local res = builder.call({
    cwd = root,
    hidden = true,
  })

  local entries = {}
  local text = table.concat(res.stdout or {}, "\n")
  for rec in (text .. REC):gmatch("(.-)" .. REC) do
    if rec ~= "" then
      local f = vim.split(rec:gsub("\n", ""), SEP, { plain = true })
      if f[1] and f[1] ~= "" then
        local bookmarks = {}
        if f[3] and f[3] ~= "" then bookmarks = vim.split(f[3], ",", { plain = true }) end
        local entry = {
          change_id = f[1],
          commit_id = f[2] or "",
          bookmarks = bookmarks,
          description = (f[4] and f[4] ~= "") and f[4] or "(no description set)",
          author = f[5] or "",
          ago = f[6] or "",
          conflict = f[7] == "true",
          empty = f[8] == "true",
          working_copy = f[9] == "true",
          files = nil,
          open = false,
        }
        -- Single-file mode: the scoped path is the only file of interest
        if path and path ~= "" then
          entry.files = { { path = path, status = "M" } }
          entry.open = false
        end
        table.insert(entries, entry)
      end
    end
  end
  return entries
end

---@param entry FileHistoryEntry
---@param root string
---@param prefer_path? string
function M.ensure_files(entry, root, prefer_path)
  if entry.files then return end
  entry.files = status_data.change_files(root, entry.change_id) or {}
  if prefer_path and prefer_path ~= "" then
    table.sort(entry.files, function(a, b)
      if a.path == prefer_path then return true end
      if b.path == prefer_path then return false end
      return a.path < b.path
    end)
  end
end

---@param entries FileHistoryEntry[]
---@param revision? string
---@param root? string
---@return integer|nil
function M.find_entry_index(entries, revision, root)
  if not revision or revision == "" then return nil end
  for i, e in ipairs(entries) do
    if
      e.change_id == revision
      or revision:sub(1, #e.change_id) == e.change_id
      or e.change_id:sub(1, #revision) == revision
    then
      return i
    end
  end
  -- Resolve via jj in case a longer / alternate id was passed
  if not root then return nil end
  local res = cli.log.revisions(revision).no_graph.template('change_id.short(8) ++ "\\n"').limit(1).call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  local short = vim.trim(table.concat(res.stdout or {}, ""))
  if short == "" then return nil end
  for i, e in ipairs(entries) do
    if e.change_id == short then return i end
  end
  return nil
end

---@param root string
---@param win integer
---@param path? string
---@return FileHistoryPanel
function M.create(root, win, path)
  local buf = Buffer.create("jujutsu://file-history/panel", "jujutsu-file-history")
  vim.api.nvim_win_set_buf(win, buf.bufnr)
  buf.winid = win
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  if config.values.disable_line_numbers then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end

  return {
    buf = buf,
    win = win,
    root = root,
    path = path,
    entries = {},
    line_map = {},
    selected_change = nil,
    selected_path = nil,
  }
end

---@param panel FileHistoryPanel
---@param count integer
function M.render(panel, count)
  local signs = config.values.signs.item or { ">", "v" }
  local single_file = panel.path and panel.path ~= ""
  local lines = {}
  local highlights = {}
  panel.line_map = {}

  local function add(text, map, hls)
    table.insert(lines, text)
    local row = #lines
    if map then panel.line_map[row] = map end
    for _, h in ipairs(hls or {}) do
      table.insert(highlights, {
        line = row - 1,
        col = h.col,
        end_col = h.end_col,
        hl = h.hl,
        line_hl = h.line_hl,
      })
    end
  end

  local title = string.format("File History (%d)", count or #panel.entries)
  add(title, { kind = "header" }, { { col = 0, end_col = #title, hl = "JujutsuPopupHeading" } })
  add(panel.root, { kind = "header" }, { { col = 0, end_col = #panel.root, hl = "JujutsuSubtle" } })
  local scope = single_file and panel.path or "(repo)"
  local scope_line = "Showing history for: " .. scope
  add(scope_line, { kind = "header" }, {
    { col = 0, end_col = #scope_line, hl = "JujutsuSubtle" },
  })
  add("", { kind = "header" }, {})

  if #panel.entries == 0 then
    add("(empty history)", { kind = "empty" }, {
      { col = 0, end_col = #"(empty history)", hl = "JujutsuSubtle" },
    })
    Buffer.render(panel.buf, lines, highlights)
    return
  end

  for i, entry in ipairs(panel.entries) do
    local open = entry.open
    local isign = single_file and " " or signs[open and 2 or 1]
    local selected = panel.selected_change == entry.change_id

    local parts = {}
    local hls = {}
    local col = 0
    local function push(str, hl)
      table.insert(parts, str)
      if hl and #str > 0 then table.insert(hls, { col = col, end_col = col + #str, hl = hl }) end
      col = col + #str
    end

    push(isign .. " ", "JujutsuSubtle")
    local id_hl = entry.working_copy and "JujutsuWorkingCopy" or "JujutsuChangeIdPrefix"
    push(entry.change_id, id_hl)
    push(" ", nil)
    push(entry.commit_id:sub(1, 8), "JujutsuCommitId")
    for _, bm in ipairs(entry.bookmarks) do
      push(" ", nil)
      push(bm, "JujutsuBranch")
    end
    push(" ", nil)
    push(entry.description, entry.description ~= "(no description set)" and "JujutsuDescription" or "JujutsuSubtle")
    if entry.author ~= "" or entry.ago ~= "" then
      local meta =
        string.format("  %s%s%s", entry.author, (entry.author ~= "" and entry.ago ~= "") and ", " or "", entry.ago)
      push(meta, "JujutsuSubtle")
    end
    if entry.conflict then push(" conflict", "JujutsuConflict") end
    if entry.empty then push(" empty", "JujutsuSubtle") end

    local line_hl = selected and "CursorLine" or nil
    local text = table.concat(parts)
    local row_hls = {}
    for _, h in ipairs(hls) do
      table.insert(row_hls, h)
    end
    if line_hl then table.insert(row_hls, { line_hl = line_hl }) end
    add(text, { kind = "change", entry = entry, index = i }, row_hls)

    if not single_file and open and entry.files then
      if #entry.files == 0 then
        add("    (no files)", { kind = "empty", entry = entry, index = i }, {
          { col = 0, end_col = #"(no files)" + 4, hl = "JujutsuSubtle" },
        })
      else
        for _, file in ipairs(entry.files) do
          local file_selected = selected and panel.selected_path == file.path
          local ftext = string.format("    %s %s", file.status, file.path)
          local fhls = {
            { col = 4, end_col = 5, hl = "JujutsuDiffHeader" },
            { col = 6, end_col = #ftext, hl = "Normal" },
          }
          if file_selected then table.insert(fhls, { line_hl = "CursorLine" }) end
          add(ftext, { kind = "file", entry = entry, file = file, index = i }, fhls)
        end
      end
    end
  end

  Buffer.render(panel.buf, lines, highlights)
end

---@param panel FileHistoryPanel
---@return { kind: string, entry?: FileHistoryEntry, file?: table, index?: integer }|nil
function M.under_cursor(panel)
  if not panel.win or not vim.api.nvim_win_is_valid(panel.win) then return nil end
  local row = vim.api.nvim_win_get_cursor(panel.win)[1]
  return panel.line_map[row]
end

---@param panel FileHistoryPanel
---@param entry FileHistoryEntry
---@param path? string
---@param prefer_cursor_row? boolean
function M.goto_entry(panel, entry, path, prefer_cursor_row)
  if not panel.win or not vim.api.nvim_win_is_valid(panel.win) then return end
  local single_file = panel.path and panel.path ~= ""
  for row, map in pairs(panel.line_map) do
    if not single_file and path then
      if map.kind == "file" and map.entry == entry and map.file and map.file.path == path then
        vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
        return
      end
    elseif map.kind == "change" and map.entry == entry then
      vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
      return
    end
  end
  if prefer_cursor_row then return end
end

---@param panel FileHistoryPanel
function M.focus(panel)
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then vim.api.nvim_set_current_win(panel.win) end
end

---@param panel FileHistoryPanel
function M.destroy(panel)
  if not panel then return end
  if panel.buf and vim.api.nvim_buf_is_valid(panel.buf.bufnr) then
    pcall(vim.api.nvim_buf_delete, panel.buf.bufnr, { force = true })
  end
end

return M
