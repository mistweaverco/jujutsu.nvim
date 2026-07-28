local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local split_mod = require("jujutsu.buffers.diff.split")
local status_data = require("jujutsu.jj.status")

local M = {}

---@class DiffViewFile
---@field path string
---@field status string

---@class DiffView
---@field root string
---@field tabpage integer
---@field title string
---@field left_rev string
---@field right_rev string
---@field files DiffViewFile[]
---@field selected_path string|nil
---@field panel_buf Buffer
---@field panel_win integer
---@field split DiffSplit
---@field line_map table<integer, DiffViewFile|nil>
---@field closing boolean

---@type DiffView|nil
local instance = nil

local function panel_height()
  local fh = config.values.file_history or {}
  return fh.panel_height or 16
end

local function close_view()
  if not instance or instance.closing then return end
  instance.closing = true
  local tab = instance.tabpage
  split_mod.destroy(instance.split)
  if instance.panel_buf and vim.api.nvim_buf_is_valid(instance.panel_buf.bufnr) then
    pcall(vim.api.nvim_buf_delete, instance.panel_buf.bufnr, { force = true })
  end
  instance = nil
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    local cur = vim.api.nvim_get_current_tabpage()
    if cur ~= tab then vim.api.nvim_set_current_tabpage(tab) end
    pcall(vim.cmd, "tabclose")
  end
end

---@param builder any
---@param root string
---@return DiffViewFile[]
local function files_from_summary_builder(builder, root)
  local res = builder.summary.call({ cwd = root, hidden = true, remove_ansi = true })
  if res.code ~= 0 then return {} end
  local files = status_data.parse_diff_summary(res.stdout)
  return files
end

---@param view DiffView
local function render_panel(view)
  local lines = {}
  local highlights = {}
  view.line_map = {}

  local function add(text, file, hls)
    table.insert(lines, text)
    local row = #lines
    view.line_map[row] = file
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

  local title = string.format("Diff %s (%d files)", view.title, #view.files)
  add(title, nil, { { col = 0, end_col = #title, hl = "JujutsuPopupHeading" } })
  local range = string.format("%s → %s", view.left_rev, view.right_rev)
  add(range, nil, { { col = 0, end_col = #range, hl = "JujutsuSubtle" } })
  add(view.root, nil, { { col = 0, end_col = #view.root, hl = "JujutsuSubtle" } })
  add("", nil, {})

  if #view.files == 0 then
    add("(no changes)", nil, { { col = 0, end_col = #"(no changes)", hl = "JujutsuSubtle" } })
  else
    for _, file in ipairs(view.files) do
      local selected = view.selected_path == file.path
      local text = string.format("  %s %s", file.status, file.path)
      local hls = {
        { col = 2, end_col = 3, hl = "JujutsuDiffHeader" },
        { col = 4, end_col = #text, hl = "Normal" },
      }
      if selected then table.insert(hls, { line_hl = "CursorLine" }) end
      add(text, file, hls)
    end
  end

  Buffer.render(view.panel_buf, lines, highlights)
end

---@param view DiffView
---@param path? string
local function select_path(view, path)
  if not path then
    view.selected_path = nil
    render_panel(view)
    split_mod.clear(view.split)
    return
  end
  view.selected_path = path
  render_panel(view)
  -- Move cursor onto the selected file row
  for row, file in pairs(view.line_map) do
    if file and file.path == path then
      if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
        vim.api.nvim_win_set_cursor(view.panel_win, { row, 0 })
      end
      break
    end
  end
  split_mod.show_sides(view.split, view.left_rev, view.right_rev, path)
end

---@param view DiffView
---@param delta integer
local function select_adjacent(view, delta)
  if #view.files == 0 then return end
  local idx = 1
  for i, f in ipairs(view.files) do
    if f.path == view.selected_path then
      idx = i
      break
    end
  end
  local next_idx = idx + delta
  if next_idx < 1 or next_idx > #view.files then return end
  select_path(view, view.files[next_idx].path)
end

---@param view DiffView
local function open_description(view)
  local rev = view.right_rev
  if not rev or rev == "" then return end
  local res = cli.log.revisions(rev).no_graph.template("description").limit(1).call({
    cwd = view.root,
    hidden = true,
  })
  local lines = res.stdout or {}
  if #lines == 0 then lines = { "(no description set)" } end

  local buf = Buffer.create("jujutsu://diff/desc/" .. rev, "jujutsu-diff-desc")
  local width = math.min(80, math.floor(vim.o.columns * 0.7))
  local height = math.min(math.max(#lines + 2, 6), math.floor(vim.o.lines * 0.5))
  local win = vim.api.nvim_open_win(buf.bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. rev .. " ",
    title_pos = "center",
  })
  Buffer.render(buf, lines, {
    { line = 0, col = 0, end_col = #(lines[1] or ""), hl = "JujutsuDescription" },
  })
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf.bufnr, silent = true })
  vim.keymap.set("n", "<esc>", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf.bufnr, silent = true })
end

---@param view DiffView
local function bind_keymaps(view)
  local bufnr = view.panel_buf.bufnr
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, noremap = true, desc = "jujutsu: " .. desc })
  end

  map("q", close_view, "Close")
  map("<esc>", close_view, "Close")

  local function open_under_cursor()
    local row = vim.api.nvim_win_get_cursor(view.panel_win)[1]
    local file = view.line_map[row]
    if file then select_path(view, file.path) end
  end

  map("<cr>", open_under_cursor, "Open")
  map("o", open_under_cursor, "Open")
  map("<tab>", function() select_adjacent(view, 1) end, "NextFile")
  map("<s-tab>", function() select_adjacent(view, -1) end, "PrevFile")
  map("L", function() open_description(view) end, "Description")

  for _, dbuf in ipairs({ view.split.left_buf, view.split.right_buf }) do
    vim.keymap.set("n", "q", close_view, { buffer = dbuf.bufnr, silent = true, noremap = true })
    vim.keymap.set("n", "<leader>e", function()
      if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
        vim.api.nvim_set_current_win(view.panel_win)
      end
    end, { buffer = dbuf.bufnr, silent = true, noremap = true, desc = "jujutsu: FocusDiffPanel" })
  end
end

---Open a side-by-side diff tab with a file list.
---@param opts { cwd: string, title?: string, left?: string, right?: string, revision?: string, builder?: any }
function M.open(opts)
  require("jujutsu.hl").setup()
  opts = opts or {}
  local root = opts.cwd
  if not root then return end

  if instance then close_view() end

  local left_rev, right_rev, title, files

  if opts.revision then
    left_rev = opts.revision .. "-"
    right_rev = opts.revision
    title = opts.title or opts.revision
    files = status_data.change_files(root, opts.revision)
  elseif opts.left and opts.right then
    left_rev = opts.left
    right_rev = opts.right
    title = opts.title or (left_rev .. ".." .. right_rev)
    local builder = opts.builder or cli.diff.from(left_rev).to(right_rev)
    files = files_from_summary_builder(builder, root)
  elseif opts.builder then
    -- Working-copy style: jj diff (parent → @)
    left_rev = "@-"
    right_rev = "@"
    title = opts.title or "wc"
    files = files_from_summary_builder(opts.builder, root)
  else
    left_rev = "@-"
    right_rev = "@"
    title = opts.title or "wc"
    files = files_from_summary_builder(cli.diff, root)
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.cmd("botright split")
  local panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(panel_win, panel_height())

  local panel_buf = Buffer.create("jujutsu://diff/panel/" .. title, "jujutsu-diff")
  vim.api.nvim_win_set_buf(panel_win, panel_buf.bufnr)
  panel_buf.winid = panel_win
  vim.wo[panel_win].cursorline = true
  vim.wo[panel_win].wrap = false
  if config.values.disable_line_numbers then
    vim.wo[panel_win].number = false
    vim.wo[panel_win].relativenumber = false
  end

  local split = split_mod.create(root, left_win, right_win, { uri_prefix = "jujutsu://diff/" .. title })

  instance = {
    root = root,
    tabpage = tabpage,
    title = title,
    left_rev = left_rev,
    right_rev = right_rev,
    files = files or {},
    selected_path = nil,
    panel_buf = panel_buf,
    panel_win = panel_win,
    split = split,
    line_map = {},
    closing = false,
  }

  bind_keymaps(instance)
  render_panel(instance)

  if #instance.files > 0 then
    select_path(instance, instance.files[1].path)
  else
    split_mod.clear(split)
  end

  vim.api.nvim_set_current_win(panel_win)

  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("JujutsuDiffView", { clear = true }),
    callback = function()
      if not instance or instance.closing then return end
      if not vim.api.nvim_tabpage_is_valid(instance.tabpage) then
        instance.closing = true
        split_mod.destroy(instance.split)
        if instance.panel_buf and vim.api.nvim_buf_is_valid(instance.panel_buf.bufnr) then
          pcall(vim.api.nvim_buf_delete, instance.panel_buf.bufnr, { force = true })
        end
        instance = nil
      end
    end,
  })
end

---Compatibility shim: old callers passed a git-format patch. Open WC-style view instead when possible.
---@param lines string[]
---@param title? string
function M.show(lines, title)
  -- Prefer opening a real side-by-side when we have a cwd from the repo
  local root = require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  if title == "trunk" or title == "main" or title == "master" then
    M.open({
      cwd = root,
      title = title,
      left = title == "trunk" and "trunk()" or title,
      right = "@",
    })
    return
  end
  -- Fallback: no usable range - open empty WC diff rather than a flat buffer
  if not lines or #lines == 0 or (lines[1] and lines[1]:match("^%(could not")) then
    require("jujutsu.notify").warn(lines and lines[1] or "No changes")
    return
  end
  M.open({ cwd = root, title = title or "diff" })
end

---Highlight helper kept for any external callers.
---@param line string
---@return string
function M.diff_line_hl(line)
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

function M.close() close_view() end

---@return boolean
function M.is_open() return instance ~= nil end

return M
