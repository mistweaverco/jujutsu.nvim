local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local mappings = require("jujutsu.ui.mappings")
local notify = require("jujutsu.notify")
local status_data = require("jujutsu.jj.status")
local watcher = require("jujutsu.watcher")

---@class StatusItem
---@field type string  -- "section" | "file" | "change" | "bookmark" | "conflict" | "header" | "diff" | "hint"
---@field text string
---@field hl? string
---@field line_hl? string  -- full-line highlight group (diff backgrounds)
---@field highlights? { col: integer, end_col: integer, hl: string }[]
---@field data? table
---@field folded? boolean
---@field depth? integer

local M = {}

--luacheck: ignore
---@type { buf: table, root: string, data: StatusData|nil, items: StatusItem[], line_map: table<integer, StatusItem>, folds: table<string, boolean>, open_diffs: table<string, boolean>, refreshing: boolean }|nil
local instance

local function status_hl(st)
  if st == "A" or st == "N" then
    return "JujutsuFileAdded"
  elseif st == "D" then
    return "JujutsuFileDeleted"
  elseif st == "?" then
    return "JujutsuFileUntracked"
  elseif st == "R" then
    return "JujutsuFileRenamed"
  end
  return "JujutsuFileModified"
end

local function mode_text(st)
  local t = config.values.status.mode_text
    or {
      M = "modified",
      A = "added",
      D = "deleted",
      R = "renamed",
      C = "copied",
      ["?"] = "untracked",
      N = "new file",
    }
  return t[st] or st
end

---@param change ChangeInfo
---@param label string
---@return string, { col: integer, end_col: integer, hl: string }[]
local function format_change_line(change, label)
  local highlights = {}
  local pad = config.values.status.HEAD_padding or 10
  local parts = {}

  local label_text = string.format("%-" .. pad .. "s", label)
  table.insert(parts, label_text)
  table.insert(highlights, {
    col = 0,
    end_col = #label_text,
    hl = label == "Change" and "JujutsuWorkingCopy" or "JujutsuHeaderLabel",
  })

  local col = #label_text + 1 -- space after label
  table.insert(parts, " ")

  local change_id = change.change_id
  table.insert(parts, change_id)
  table.insert(highlights, { col = col, end_col = col + #change_id, hl = "JujutsuChangeIdPrefix" })
  col = col + #change_id

  if config.values.status.show_head_commit_hash then
    table.insert(parts, " ")
    col = col + 1
    local commit_id = change.commit_id
    table.insert(parts, commit_id)
    table.insert(highlights, { col = col, end_col = col + #commit_id, hl = "JujutsuCommitId" })
    col = col + #commit_id
  end

  if change.bookmarks and #change.bookmarks > 0 then
    for _, bm in ipairs(change.bookmarks) do
      table.insert(parts, " ")
      col = col + 1
      table.insert(parts, bm)
      table.insert(highlights, { col = col, end_col = col + #bm, hl = "JujutsuBranch" })
      col = col + #bm
    end
  end

  table.insert(parts, " ")
  col = col + 1
  local desc = change.description ~= "" and change.description or "(no description set)"
  table.insert(parts, desc)
  table.insert(highlights, {
    col = col,
    end_col = col + #desc,
    hl = change.description ~= "" and "JujutsuDescription" or "JujutsuSubtle",
  })

  return table.concat(parts), highlights
end

local function ensure_folds()
  if not instance then return end
  local sections = config.values.sections
  instance.folds = instance.folds
    or {
      files = sections.files.folded,
      conflicts = sections.conflicts.folded,
      recent = sections.recent.folded,
      bookmarks = sections.bookmarks.folded,
      head = config.values.status.HEAD_folded,
    }
  instance.open_diffs = instance.open_diffs or {}
end

---@return StatusItem[], table<integer, StatusItem>
local function build_items()
  local data = instance.data
  local items = {}
  local line_map = {}
  ensure_folds()

  local function add(item) table.insert(items, item) end

  if not config.values.disable_hint then
    add({
      type = "hint",
      text = "Hint: ? help  |  c change  |  b bookmark  |  l log  |  p push  |  u undo  |  q quit",
      hl = "JujutsuHint",
    })
    add({ type = "blank", text = "" })
  end

  -- Working copy / parent headers
  if data.working_copy then
    local text, highlights = format_change_line(data.working_copy, "Change")
    add({
      type = "header",
      text = text,
      highlights = highlights,
      data = { change = data.working_copy, kind = "working_copy" },
    })
  end
  if data.parent then
    local text, highlights = format_change_line(data.parent, "Parent")
    add({
      type = "header",
      text = text,
      highlights = highlights,
      data = { change = data.parent, kind = "parent" },
    })
  end
  add({ type = "blank", text = "" })

  local function section(key, title, count, render_body)
    local sec = config.values.sections[key]
    if sec and sec.hidden then return end
    local folded = instance.folds[key]
    local sign = (config.values.signs.section or { ">", "v" })[folded and 1 or 2]
    local count_text = string.format("(%d)", count)
    local text = string.format("%s %s %s", sign, title, count_text)
    local highlights = {
      { col = 0, end_col = #sign, hl = "JujutsuFold" },
      { col = #sign + 1, end_col = #sign + 1 + #title, hl = "JujutsuSectionHeader" },
      {
        col = #sign + 1 + #title + 1,
        end_col = #text,
        hl = "JujutsuSectionCount",
      },
    }
    add({
      type = "section",
      text = text,
      highlights = highlights,
      data = { section = key },
      folded = folded,
    })
    if not folded then render_body() end
    add({ type = "blank", text = "" })
  end

  -- Conflicts
  if #data.conflicts > 0 then
    section("conflicts", "Conflicts", #data.conflicts, function()
      for _, path in ipairs(data.conflicts) do
        add({
          type = "conflict",
          text = "    " .. path,
          hl = "JujutsuConflict",
          data = { path = path },
        })
      end
    end)
  end

  -- Files
  section("files", "Working copy changes", #data.files, function()
    if #data.files == 0 then
      add({ type = "hint", text = "    (empty)", hl = "JujutsuHint" })
      return
    end
    for _, file in ipairs(data.files) do
      local open = instance.open_diffs[file.path]
      local isign = (config.values.signs.item or { ">", "v" })[open and 2 or 1]
      local mode = mode_text(file.status)
      local text = string.format("  %s %s %s", isign, mode, file.path)
      -- neoJJ: only mode is highlighted; filename stays Normal/subtle
      local col_sign = 2
      local col_mode = col_sign + #isign + 1
      add({
        type = "file",
        text = text,
        highlights = {
          { col = col_sign, end_col = col_sign + #isign, hl = "JujutsuFold" },
          { col = col_mode, end_col = col_mode + #mode, hl = status_hl(file.status) },
        },
        data = { file = file },
      })
      if open and file.diff then
        for di, dline in ipairs(file.diff) do
          -- Classify git-format diff lines (neoJJ-style line backgrounds)
          local line_hl = "JujutsuDiffContext"
          local first = dline:sub(1, 1)
          if dline:match("^@@") then
            line_hl = "JujutsuHunkHeader"
          elseif
            dline:match("^diff ")
            or dline:match("^index ")
            or dline:match("^%-%-%-")
            or dline:match("^%+%+%+")
          then
            line_hl = "JujutsuDiffHeader"
          elseif first == "+" then
            line_hl = "JujutsuDiffAdd"
          elseif first == "-" then
            line_hl = "JujutsuDiffDelete"
          end
          add({
            type = "diff",
            text = "    " .. dline,
            line_hl = line_hl,
            data = { file = file, diff_index = di },
          })
        end
      end
    end
  end)

  -- Recent
  section("recent", "Recent commits", #data.recent, function()
    for _, change in ipairs(data.recent) do
      local highlights = {}
      local parts = { "  " }
      local col = 2

      table.insert(parts, change.change_id)
      table.insert(highlights, { col = col, end_col = col + #change.change_id, hl = "JujutsuChangeIdPrefix" })
      col = col + #change.change_id

      table.insert(parts, " ")
      col = col + 1
      table.insert(parts, change.commit_id)
      table.insert(highlights, { col = col, end_col = col + #change.commit_id, hl = "JujutsuCommitId" })
      col = col + #change.commit_id

      if #change.bookmarks > 0 then
        for _, bm in ipairs(change.bookmarks) do
          table.insert(parts, " ")
          col = col + 1
          table.insert(parts, bm)
          table.insert(highlights, { col = col, end_col = col + #bm, hl = "JujutsuBranch" })
          col = col + #bm
        end
      end

      table.insert(parts, " ")
      col = col + 1
      local desc = change.description ~= "" and change.description or "(no description set)"
      table.insert(parts, desc)
      table.insert(highlights, {
        col = col,
        end_col = col + #desc,
        hl = change.description ~= "" and "JujutsuDescription" or "JujutsuSubtle",
      })

      add({
        type = "change",
        text = table.concat(parts),
        highlights = highlights,
        data = { change = change },
      })
    end
  end)

  -- Bookmarks
  local show_remote = config.values.sections.bookmarks.show_remote ~= false
  local show_deleted = config.values.sections.bookmarks.show_deleted ~= false
  local visible_bms = {}
  for _, bm in ipairs(data.bookmarks) do
    if bm.remote ~= "git" and (show_remote or bm.remote == "") and (show_deleted or not bm.deleted) then
      table.insert(visible_bms, bm)
    end
  end
  table.sort(visible_bms, function(a, b)
    local a_remote = a.remote ~= ""
    local b_remote = b.remote ~= ""
    if a_remote ~= b_remote then return not a_remote end
    if a.timestamp ~= b.timestamp then return (a.timestamp or "") > (b.timestamp or "") end
    return a.name < b.name
  end)
  section("bookmarks", "Bookmarks", #visible_bms, function()
    for _, bm in ipairs(visible_bms) do
      local name = bm.name
      if bm.remote ~= "" then name = name .. "@" .. bm.remote end
      local pr = bm.pr and string.format(" #%d", bm.pr) or ""
      local detail = string.format("%s %s %s", bm.change_id or "", bm.commit_id or "", bm.description or "")
      local text = string.format("  %s%s %s", name, pr, detail)
      local name_hl = bm.remote ~= "" and "JujutsuRemoteBranch" or "JujutsuBranch"
      local highlights = {
        { col = 2, end_col = 2 + #name, hl = name_hl },
      }
      if pr ~= "" then
        table.insert(highlights, {
          col = 2 + #name,
          end_col = 2 + #name + #pr,
          hl = "JujutsuForgePR",
        })
      end
      table.insert(highlights, {
        col = 2 + #name + #pr + 1,
        end_col = #text,
        hl = "JujutsuObjectId",
      })
      add({
        type = "bookmark",
        text = text,
        highlights = highlights,
        data = { bookmark = bm },
      })
    end
  end)

  for i, item in ipairs(items) do
    line_map[i] = item
  end
  return items, line_map
end

local function redraw()
  if not instance or not Buffer.is_open(instance.buf) then return end
  local items, line_map = build_items()
  instance.items = items
  instance.line_map = line_map
  local lines = {}
  local highlights = {}
  for i, item in ipairs(items) do
    lines[i] = item.text
    if item.line_hl then table.insert(highlights, {
      line = i - 1,
      line_hl = item.line_hl,
    }) end
    if item.highlights then
      for _, h in ipairs(item.highlights) do
        table.insert(highlights, {
          line = i - 1,
          col = h.col,
          end_col = h.end_col,
          hl = h.hl,
        })
      end
    elseif item.hl and item.text ~= "" then
      table.insert(highlights, {
        line = i - 1,
        col = 0,
        end_col = #item.text,
        hl = item.hl,
      })
    end
  end
  local cursor = { 1, 0 }
  if instance.buf.winid and vim.api.nvim_win_is_valid(instance.buf.winid) then
    cursor = vim.api.nvim_win_get_cursor(instance.buf.winid)
  end
  Buffer.render(instance.buf, lines, highlights)
  if instance.buf.winid and vim.api.nvim_win_is_valid(instance.buf.winid) then
    local max = math.max(1, #lines)
    local row = math.min(cursor[1], max)
    pcall(vim.api.nvim_win_set_cursor, instance.buf.winid, { row, 0 })
  end
end

function M.refresh()
  if not instance or instance.refreshing then return end
  instance.refreshing = true
  async.void(function()
    local ok, data = pcall(status_data.fetch, instance.root)
    instance.refreshing = false
    if not ok then
      notify.error("Failed to refresh status: " .. tostring(data))
      return
    end
    instance.data = data
    -- Re-fetch open diffs
    for path, open in pairs(instance.open_diffs or {}) do
      if open then
        for _, f in ipairs(data.files) do
          if f.path == path then f.diff = status_data.file_diff(instance.root, path) end
        end
      end
    end
    vim.schedule(redraw)
  end)
end

local function item_under_cursor()
  if not instance then return nil end
  local win = instance.buf.winid
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return instance.line_map[row]
end

local function get_change_from_item(item)
  if not item or not item.data then return nil end
  if item.data.change then return item.data.change end
  if item.data.bookmark then
    return {
      change_id = item.data.bookmark.change_id or item.data.bookmark.target,
      bookmarks = { item.data.bookmark.name },
    }
  end
  return nil
end

local function after_action() M.refresh() end

local function run_jj(fn)
  async.void(function()
    fn()
    vim.schedule(after_action)
  end)
end

---Capture file/hunk selection from the cursor or active visual range.
---Call this while visual mode is still active (e.g. before opening a popup).
---@return { path: string, mode: "file"|"hunks", hunk_indices: integer[], file: FileStatus }|nil
function M.capture_selection()
  if not instance or not instance.line_map then return nil end

  local mode = vim.fn.mode()
  local first, last = vim.fn.line("."), vim.fn.line(".")
  if mode == "v" or mode == "V" or mode == "\22" then
    first = vim.fn.line("v")
    last = vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end

  ---@type table<string, { file: FileStatus, on_file: boolean, hunks: table<integer, boolean> }>
  local by_path = {}
  for row = first, last do
    local it = instance.line_map[row]
    if it and it.data and it.data.file then
      local file = it.data.file
      local path = file.path
      by_path[path] = by_path[path] or { file = file, on_file = false, hunks = {} }
      if it.type == "file" then
        by_path[path].on_file = true
      elseif it.type == "diff" and file.diff and it.data.diff_index then
        local parsed = require("jujutsu.diff.hunks").parse_hunks(file.diff)
        local idx = require("jujutsu.diff.hunks").hunk_index_at(parsed, it.data.diff_index)
        if idx ~= nil then by_path[path].hunks[idx] = true end
      end
    end
  end

  -- Prefer the path under the anchor cursor/end of selection.
  local prefer = instance.line_map[last] or instance.line_map[first]
  local prefer_path = prefer and prefer.data and prefer.data.file and prefer.data.file.path

  local path = prefer_path
  if not path or not by_path[path] then
    path = next(by_path)
  end
  if not path then return nil end

  local entry = by_path[path]
  local indices = {}
  for idx in pairs(entry.hunks) do
    indices[#indices + 1] = idx
  end
  table.sort(indices)

  if #indices > 0 then
    return {
      path = path,
      mode = "hunks",
      hunk_indices = indices,
      file = entry.file,
    }
  end
  if entry.on_file or (prefer and prefer.type == "file") then
    return {
      path = path,
      mode = "file",
      hunk_indices = {},
      file = entry.file,
    }
  end
  -- Cursor on a diff header line with no hunk match → treat as file
  return {
    path = path,
    mode = "file",
    hunk_indices = {},
    file = entry.file,
  }
end

local function get_env(opts)
  opts = opts or {}
  local item = item_under_cursor()
  local change = get_change_from_item(item)
  local env = {
    item = item,
    change = change,
    commit = change and change.change_id or nil,
    root = instance and instance.root,
  }
  if opts.with_selection then env.selection = M.capture_selection() end
  return env
end

local function bind_actions(bufnr)
  local actions = {
    Close = function() M.close() end,
    RefreshBuffer = function() M.refresh() end,
    Toggle = function()
      local item = item_under_cursor()
      if not item then return end
      if item.type == "section" and item.data and item.data.section then
        instance.folds[item.data.section] = not instance.folds[item.data.section]
        redraw()
      elseif item.type == "file" and item.data and item.data.file then
        local path = item.data.file.path
        if instance.open_diffs[path] then
          instance.open_diffs[path] = nil
        else
          instance.open_diffs[path] = true
          item.data.file.diff = status_data.file_diff(instance.root, path)
          -- also update in data.files
          for _, f in ipairs(instance.data.files) do
            if f.path == path then f.diff = item.data.file.diff end
          end
        end
        redraw()
      end
    end,
    OpenFold = function()
      local item = item_under_cursor()
      if item and item.type == "section" and item.data then
        instance.folds[item.data.section] = false
        redraw()
      end
    end,
    CloseFold = function()
      local item = item_under_cursor()
      if item and item.type == "section" and item.data then
        instance.folds[item.data.section] = true
        redraw()
      end
    end,
    Depth1 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = true
      end
      instance.open_diffs = {}
      redraw()
    end,
    Depth2 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = false
      end
      instance.open_diffs = {}
      redraw()
    end,
    Depth3 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = false
      end
      redraw()
    end,
    Depth4 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = false
      end
      for _, f in ipairs(instance.data.files) do
        instance.open_diffs[f.path] = true
        f.diff = status_data.file_diff(instance.root, f.path)
      end
      redraw()
    end,
    MoveDown = function() vim.cmd("normal! j") end,
    MoveUp = function() vim.cmd("normal! k") end,
    GoToFile = function()
      local item = item_under_cursor()
      if not item then return end
      if item.data and item.data.file then
        local path = instance.root .. "/" .. item.data.file.path
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        return
      end
      if item.data and item.data.path then
        vim.cmd("edit " .. vim.fn.fnameescape(instance.root .. "/" .. item.data.path))
        return
      end
      -- Recent commits / Change / Parent / bookmark target → commit view
      local change = get_change_from_item(item)
      if change and change.change_id and change.change_id ~= "" then
        require("jujutsu.buffers.commit_view").open(instance.root, change.change_id)
      end
    end,
    OpenStat = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item) or (instance.data and instance.data.working_copy)
      if change and change.change_id and change.change_id ~= "" then
        require("jujutsu.buffers.stat_view").open(instance.root, change.change_id)
      end
    end,
    VSplitOpen = function()
      local item = item_under_cursor()
      local path = item and item.data and (item.data.file and item.data.file.path or item.data.path)
      if path then vim.cmd("vsplit " .. vim.fn.fnameescape(instance.root .. "/" .. path)) end
    end,
    SplitOpen = function()
      local item = item_under_cursor()
      local path = item and item.data and (item.data.file and item.data.file.path or item.data.path)
      if path then vim.cmd("split " .. vim.fn.fnameescape(instance.root .. "/" .. path)) end
    end,
    TabOpen = function()
      local item = item_under_cursor()
      local path = item and item.data and (item.data.file and item.data.file.path or item.data.path)
      if path then vim.cmd("tabedit " .. vim.fn.fnameescape(instance.root .. "/" .. path)) end
    end,
    Discard = function()
      local item = item_under_cursor()
      if not item then return end
      if item.type == "file" and item.data.file then
        local path = item.data.file.path
        vim.ui.select({ "Yes", "No" }, { prompt = "Restore " .. path .. "?" }, function(choice)
          if choice == "Yes" then
            run_jj(function() return cli.restore.paths(path).call_async({ cwd = instance.root, hidden = false }) end)
          end
        end)
      elseif item.type == "change" or item.type == "header" then
        local change = get_change_from_item(item)
        if change then
          vim.ui.select({ "Yes", "No" }, { prompt = "Abandon " .. change.change_id .. "?" }, function(choice)
            if choice == "Yes" then
              run_jj(
                function() return cli.abandon.args(change.change_id).call_async({ cwd = instance.root, hidden = false }) end
              )
            end
          end)
        end
      elseif item.type == "bookmark" and item.data.bookmark then
        local bm = item.data.bookmark
        local name = bm.remote ~= "" and (bm.name .. "@" .. bm.remote) or bm.name
        vim.ui.select({ "Yes", "No" }, { prompt = "Delete bookmark " .. name .. "?" }, function(choice)
          if choice == "Yes" then
            run_jj(
              function() return cli.bookmark_delete.args(name).call_async({ cwd = instance.root, hidden = false }) end
            )
          end
        end)
      end
    end,
    Untrack = function()
      local item = item_under_cursor()
      if item and item.type == "file" and item.data.file then
        run_jj(
          function()
            return cli.file_untrack.paths(item.data.file.path).call_async({ cwd = instance.root, hidden = false })
          end
        )
      end
    end,
    Describe = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item) or (instance.data and instance.data.working_copy)
      if change then
        require("jujutsu.buffers.editor").open({
          revision = change.change_id,
          root = instance.root,
          on_submit = after_action,
        })
      end
    end,
    Edit = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      if change then
        run_jj(
          function() return cli.edit.args(change.change_id).call_async({ cwd = instance.root, hidden = false }) end
        )
      end
    end,
    Split = function()
      require("jujutsu.popups.split").create(get_env({ with_selection = true }))
    end,
    NewOn = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      local rev = change and change.change_id or "@"
      run_jj(function() return cli.new.args(rev).call_async({ cwd = instance.root, hidden = false }) end)
    end,
    NewBefore = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      local rev = change and change.change_id or "@"
      run_jj(function() return cli.new.insert_before.args(rev).call_async({ cwd = instance.root, hidden = false }) end)
    end,
    ForgetBookmark = function()
      local item = item_under_cursor()
      if item and item.type == "bookmark" and item.data.bookmark then
        local bm = item.data.bookmark
        if bm.remote ~= "" then
          run_jj(
            function()
              return require("jujutsu.jj.bookmark").track(bm.name .. "@" .. bm.remote).call_async({
                cwd = instance.root,
                hidden = false,
              })
            end
          )
        else
          run_jj(
            function() return cli.bookmark_forget.args(bm.name).call_async({ cwd = instance.root, hidden = false }) end
          )
        end
      end
    end,
    OpenBrowser = function() require("jujutsu.forge").open_under_cursor(get_env()) end,
    YankSelected = function()
      local item = item_under_cursor()
      if not item then return end
      local text = item.text:match("^%s*(.-)%s*$") or item.text
      if item.data and item.data.change then
        text = item.data.change.change_id
      elseif item.data and item.data.file then
        text = item.data.file.path
      elseif item.data and item.data.bookmark then
        text = item.data.bookmark.name
      end
      vim.fn.setreg("+", text)
      notify.info("Yanked " .. text)
    end,
    CommandHistory = function() require("jujutsu.buffers.process").show_history() end,
    Command = function()
      vim.ui.input({ prompt = "jj " }, function(input)
        if not input or input == "" then return end
        local args = vim.split(input, "%s+")
        local jj = require("jujutsu.jj.shell").resolve_jj()
        run_jj(
          function()
            return require("jujutsu.process").await({
              cmd = vim.list_extend({ jj, "--no-pager" }, args),
              cwd = instance.root,
              suppress_console = false,
            })
          end
        )
      end)
    end,
    ShowRefs = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      if change then notify.info(string.format("change=%s commit=%s", change.change_id, change.commit_id)) end
    end,
    NextSection = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      for i = row + 1, #instance.items do
        if instance.items[i].type == "section" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end,
    PreviousSection = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      for i = row - 1, 1, -1 do
        if instance.items[i].type == "section" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end,
    GoToPreviousHunkHeader = function() vim.fn.search("^\\s*@@", "bW") end,
    GoToNextHunkHeader = function() vim.fn.search("^\\s*@@", "W") end,
  }

  mappings.apply(bufnr, "status", actions)
  mappings.apply_popup_maps(bufnr, get_env)
  -- Visual-mode Split so hunk ranges can be selected before opening the popup.
  local status_maps = require("jujutsu.config").values.mappings.status or {}
  for key, name in pairs(status_maps) do
    if name == "Split" and actions.Split then
      vim.keymap.set("x", key, actions.Split, {
        buffer = bufnr,
        silent = true,
        noremap = true,
        desc = "jujutsu: Split",
      })
    end
  end
end

---@param root string
---@param cwd string
---@param opts? { kind?: string }
---@return table
function M.open(root, cwd, opts)
  opts = opts or {}
  if instance and Buffer.is_open(instance.buf) then
    Buffer.focus(instance.buf)
    M.refresh()
    return instance
  end

  local buf = Buffer.create("jujutsu://status", "jujutsu")
  Buffer.open(buf, opts.kind or config.values.kind)
  Buffer.apply_buffer_opts(buf.bufnr)

  instance = {
    buf = buf,
    root = root,
    cwd = cwd,
    data = nil,
    items = {},
    line_map = {},
    folds = nil,
    open_diffs = {},
    refreshing = false,
  }

  bind_actions(buf.bufnr)
  watcher.start(root, function() M.refresh() end)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf.bufnr,
    once = true,
    callback = function()
      watcher.stop()
      instance = nil
    end,
  })

  M.refresh()
  return instance
end

function M.close()
  if instance then
    watcher.stop()
    Buffer.close(instance.buf)
    instance = nil
  end
end

function M.instance() return instance end

function M.focus()
  if instance then Buffer.focus(instance.buf) end
end

function M.get_env() return get_env() end

return M
