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
---@field review ReviewSession|nil

---@type DiffView|nil
local instance = nil

local function panel_height()
  local fh = config.values.file_history or {}
  return fh.panel_height or 16
end

local function refresh_overlays(view)
  if not view or not view.review or not view.selected_path then return end
  local overlay = require("jujutsu.review.overlay")
  local session_mod = require("jujutsu.review.session")
  local comments = session_mod.all_overlay_comments(view.review)
  overlay.render(view.split.left_buf.bufnr, comments, view.selected_path, "LEFT")
  overlay.render(view.split.right_buf.bufnr, comments, view.selected_path, "RIGHT")
end

local function close_view()
  if not instance or instance.closing then return end

  local function do_close()
    if not instance or instance.closing then return end
    instance.closing = true
    local tab = instance.tabpage
    if instance.review then pcall(require("jujutsu.review.session").save, instance.review) end
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

  if instance.review and instance.review.dirty and #(instance.review.comments or {}) > 0 then
    vim.ui.select({ "Save & close", "Close without saving", "Cancel" }, {
      prompt = "Unsaved review comments",
    }, function(choice)
      if choice == "Cancel" or not choice then return end
      if choice == "Save & close" then require("jujutsu.review.session").save(instance.review) end
      do_close()
    end)
    return
  end
  do_close()
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
  if view.review then
    title = string.format(
      "Review %s (%d files, %d local, %d remote)",
      view.title,
      #view.files,
      #(view.review.comments or {}),
      #(view.review.remote_comments or {})
    )
  end
  add(title, nil, { { col = 0, end_col = #title, hl = "JujutsuPopupHeading" } })
  local range = string.format("%s → %s", view.left_rev, view.right_rev)
  add(range, nil, { { col = 0, end_col = #range, hl = "JujutsuSubtle" } })
  add(view.root, nil, { { col = 0, end_col = #view.root, hl = "JujutsuSubtle" } })
  if view.review then
    local hint = "c comment  C file  S submit  y yank  r reviewed  ? help"
    add(hint, nil, { { col = 0, end_col = #hint, hl = "JujutsuHint" } })
  end
  add("", nil, {})

  if #view.files == 0 then
    add("(no changes)", nil, { { col = 0, end_col = #"(no changes)", hl = "JujutsuSubtle" } })
  else
    for _, file in ipairs(view.files) do
      local selected = view.selected_path == file.path
      local reviewed = view.review and view.review.reviewed_files[file.path]
      local mark = reviewed and "✓" or " "
      local text = string.format("  %s %s %s", mark, file.status, file.path)
      local hls = {
        { col = 2, end_col = 3, hl = reviewed and "JujutsuReviewReviewed" or "JujutsuSubtle" },
        { col = 4, end_col = 5, hl = "JujutsuDiffHeader" },
        { col = 6, end_col = #text, hl = "Normal" },
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
  for row, file in pairs(view.line_map) do
    if file and file.path == path then
      if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
        vim.api.nvim_win_set_cursor(view.panel_win, { row, 0 })
      end
      break
    end
  end
  split_mod.show_sides(view.split, view.left_rev, view.right_rev, path)
  refresh_overlays(view)
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
---@param side "LEFT"|"RIGHT"
---@param kind "line"|"range"|"file"|"review"
---@param start_line? integer
---@param end_line? integer
local function add_comment(view, side, kind, start_line, end_line)
  if not view.review then return end
  local comments_mod = require("jujutsu.review.comments")
  local session_mod = require("jujutsu.review.session")
  local ui = require("jujutsu.review.ui")
  local path = view.selected_path
  local prompt_title
  if kind == "file" then
    prompt_title = "File comment: " .. (path or "")
  elseif kind == "review" then
    prompt_title = "Review comment"
  elseif kind == "range" then
    prompt_title = string.format("Range %s:%d-%d", path or "?", start_line or 0, end_line or 0)
  else
    prompt_title = string.format("Line %s:%d", path or "?", end_line or start_line or 0)
  end

  ui.prompt_comment(prompt_title, {}, function(body)
    if not body then return end
    local comment = comments_mod.new({
      kind = kind,
      path = (kind ~= "review") and path or nil,
      side = (kind == "line" or kind == "range") and side or nil,
      line = end_line or start_line,
      start_line = kind == "range" and start_line or nil,
      body = body,
    })
    session_mod.add_comment(view.review, comment)
    render_panel(view)
    refresh_overlays(view)
  end)
end

---@param view DiffView
---@param side "LEFT"|"RIGHT"
---@param line integer
---@return table|nil local pending comment at line
local function local_comment_at(view, side, line)
  if not view.review or not view.selected_path then return nil end
  for _, c in ipairs(view.review.comments or {}) do
    local kind = c.kind or "line"
    if
      not c.remote
      and c.path == view.selected_path
      and (kind == "line" or kind == "range")
      and (c.side or "RIGHT") == side
      and tonumber(c.line) == line
    then
      return c
    end
  end
  return nil
end

---@param view DiffView
local function edit_comment_at_cursor(view)
  if not view.review then return end
  local side = vim.api.nvim_get_current_buf() == view.split.left_buf.bufnr and "LEFT" or "RIGHT"
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local comment = local_comment_at(view, side, line)
  if not comment then
    require("jujutsu.notify").warn("No unsubmitted comment on this line")
    return
  end
  local session_mod = require("jujutsu.review.session")
  local ui = require("jujutsu.review.ui")
  ui.prompt_comment("Edit comment", { initial = comment.body or "" }, function(body)
    if not body then return end
    session_mod.update_comment(view.review, comment.id, body)
    render_panel(view)
    refresh_overlays(view)
  end)
end

---@param view DiffView
local function bind_review_keymaps(view)
  if not view.review then return end
  local overlay = require("jujutsu.review.overlay")
  local ui = require("jujutsu.review.ui")
  local session_mod = require("jujutsu.review.session")

  local function side_for_buf(bufnr)
    if bufnr == view.split.left_buf.bufnr then return "LEFT" end
    return "RIGHT"
  end

  local function map_diff(lhs, rhs, desc)
    for _, dbuf in ipairs({ view.split.left_buf, view.split.right_buf }) do
      vim.keymap.set("n", lhs, rhs, {
        buffer = dbuf.bufnr,
        silent = true,
        noremap = true,
        desc = "jujutsu review: " .. desc,
      })
    end
  end

  map_diff("c", function()
    local side = side_for_buf(vim.api.nvim_get_current_buf())
    local line = vim.api.nvim_win_get_cursor(0)[1]
    add_comment(view, side, "line", line, line)
  end, "CommentLine")

  map_diff("C", function() add_comment(view, "RIGHT", "file") end, "CommentFile")

  for _, dbuf in ipairs({ view.split.left_buf, view.split.right_buf }) do
    vim.keymap.set("v", "c", function()
      local side = side_for_buf(dbuf.bufnr)
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      if start_line == end_line then
        add_comment(view, side, "line", start_line, end_line)
      else
        add_comment(view, side, "range", start_line, end_line)
      end
    end, { buffer = dbuf.bufnr, silent = true, noremap = true, desc = "jujutsu review: CommentRange" })
  end

  map_diff(";c", function() add_comment(view, "RIGHT", "review") end, "CommentReview")

  map_diff("e", function() edit_comment_at_cursor(view) end, "EditComment")
  map_diff("i", function() edit_comment_at_cursor(view) end, "EditComment")

  map_diff("m", function()
    if not view.selected_path then return end
    local side = side_for_buf(vim.api.nvim_get_current_buf())
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local all = session_mod.all_overlay_comments(view.review)
    local next_line = overlay.next_comment_line(all, view.selected_path, side, cur, 1)
    if next_line then vim.api.nvim_win_set_cursor(0, { next_line, 0 }) end
  end, "NextComment")

  map_diff("M", function()
    if not view.selected_path then return end
    local side = side_for_buf(vim.api.nvim_get_current_buf())
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local all = session_mod.all_overlay_comments(view.review)
    local prev = overlay.next_comment_line(all, view.selected_path, side, cur, -1)
    if prev then vim.api.nvim_win_set_cursor(0, { prev, 0 }) end
  end, "PrevComment")

  map_diff("y", function() ui.copy_markdown(session_mod.markdown(view.review)) end, "YankMarkdown")

  map_diff("S", function()
    require("jujutsu.review.submit").pick_and_submit(view.review, function(ok)
      if ok then render_panel(view) end
    end)
  end, "Submit")

  map_diff(
    "?",
    function()
      ui.help(table.concat({
        "Review keymaps",
        "",
        "c        comment at cursor line",
        "C        file comment",
        "v/V + c  range comment",
        ";c       review-level comment",
        "e / i    edit unsubmitted comment at cursor",
        "m / M    next / previous comment",
        "r        toggle file reviewed (panel)",
        "y        yank markdown",
        "S        submit review",
        "q        close",
      }, "\n"))
    end,
    "Help"
  )
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

  if view.review then
    map("r", function()
      local row = vim.api.nvim_win_get_cursor(view.panel_win)[1]
      local file = view.line_map[row]
      if not file then return end
      require("jujutsu.review.session").toggle_reviewed(view.review, file.path)
      render_panel(view)
    end, "ToggleReviewed")
    map("y", function()
      local md = require("jujutsu.review.session").markdown(view.review)
      require("jujutsu.review.ui").copy_markdown(md)
    end, "YankMarkdown")
    map("S", function()
      require("jujutsu.review.submit").pick_and_submit(view.review, function(ok)
        if ok then render_panel(view) end
      end)
    end, "Submit")
    map(
      "?",
      function()
        require("jujutsu.review.ui").help(table.concat({
          "Review keymaps",
          "",
          "c        comment at cursor line (diff)",
          "C        file comment (diff)",
          "v/V + c  range comment (diff)",
          ";c       review-level comment",
          "e / i    edit unsubmitted comment at cursor",
          "m / M    next / previous comment",
          "r        toggle file reviewed",
          "y        yank markdown",
          "S        submit review",
          "q        close",
        }, "\n"))
      end,
      "Help"
    )
  end

  for _, dbuf in ipairs({ view.split.left_buf, view.split.right_buf }) do
    vim.keymap.set("n", "q", close_view, { buffer = dbuf.bufnr, silent = true, noremap = true })
    vim.keymap.set("n", "<leader>e", function()
      if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
        vim.api.nvim_set_current_win(view.panel_win)
      end
    end, { buffer = dbuf.bufnr, silent = true, noremap = true, desc = "jujutsu: FocusDiffPanel" })
  end

  bind_review_keymaps(view)
end

---Open a side-by-side diff tab with a file list.
-- luacheck: ignore 631
---@param opts { cwd: string, title?: string, left?: string, right?: string, revision?: string, builder?: any, review?: ReviewSession }
function M.open(opts)
  require("jujutsu.hl").setup()
  opts = opts or {}
  local root = opts.cwd
  if not root then return end

  if instance then close_view() end
  -- If close prompted, instance may still be open
  if instance then return end

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

  if opts.review then
    title = opts.title or opts.review.title or title
    left_rev = opts.review.left_rev or left_rev
    right_rev = opts.review.right_rev or right_rev
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
    review = opts.review,
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

---@return DiffView|nil
function M.instance() return instance end

return M
