local config = require("jujutsu.config")
local notify = require("jujutsu.notify")
local panel_mod = require("jujutsu.buffers.file_history.panel")
local view_mod = require("jujutsu.buffers.annotate.view")

local M = {}

---@class AnnotateSession
---@field root string
---@field path string
---@field tabpage integer
---@field view AnnotateView
---@field panel FileHistoryPanel
---@field closing boolean

---@type AnnotateSession|nil
local instance = nil

local function cfg() return config.values.annotate or {} end

local function close_view()
  if not instance or instance.closing then return end
  instance.closing = true
  local tab = instance.tabpage
  view_mod.destroy(instance.view)
  panel_mod.destroy(instance.panel)
  instance = nil
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    local cur = vim.api.nvim_get_current_tabpage()
    if cur ~= tab then vim.api.nvim_set_current_tabpage(tab) end
    pcall(vim.cmd, "tabclose")
  end
end

---@param session AnnotateSession
---@param entry FileHistoryEntry
local function select_change(session, entry)
  session.panel.selected_change = entry.change_id
  session.panel.selected_path = session.path
  panel_mod.render(session.panel, #session.panel.entries)
  panel_mod.goto_entry(session.panel, entry, session.path)
  view_mod.highlight_change(session.view, entry.change_id)
end

---@param session AnnotateSession
---@param delta integer
local function select_adjacent(session, delta)
  local entries = session.panel.entries
  if #entries == 0 then return end
  local cur_idx = 1
  for i, e in ipairs(entries) do
    if e.change_id == session.panel.selected_change then
      cur_idx = i
      break
    end
  end
  local next_idx = cur_idx + delta
  if next_idx < 1 or next_idx > #entries then return end
  select_change(session, entries[next_idx])
end

---@param session AnnotateSession
local function bind_keymaps(session)
  local function map(bufnr, lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = bufnr,
      silent = true,
      noremap = true,
      desc = "jujutsu: " .. desc,
    })
  end

  local panel_buf = session.panel.buf.bufnr
  local view_buf = session.view.buf.bufnr

  for _, bufnr in ipairs({ panel_buf, view_buf }) do
    map(bufnr, "q", close_view, "Close")
    map(bufnr, "<esc>", close_view, "Close")
  end

  map(panel_buf, "<cr>", function()
    local item = panel_mod.under_cursor(session.panel)
    if item and item.entry then select_change(session, item.entry) end
  end, "HighlightChange")

  map(panel_buf, "o", function()
    local item = panel_mod.under_cursor(session.panel)
    if item and item.entry then select_change(session, item.entry) end
  end, "HighlightChange")

  map(panel_buf, "<tab>", function() select_adjacent(session, 1) end, "NextChange")
  map(panel_buf, "<s-tab>", function() select_adjacent(session, -1) end, "PrevChange")

  map(panel_buf, "y", function()
    local item = panel_mod.under_cursor(session.panel)
    local entry = item and item.entry
    if not entry and session.panel.selected_change then
      for _, e in ipairs(session.panel.entries) do
        if e.change_id == session.panel.selected_change then
          entry = e
          break
        end
      end
    end
    if entry then
      vim.fn.setreg("+", entry.change_id)
      vim.fn.setreg('"', entry.change_id)
      notify.info("Yanked " .. entry.change_id)
    end
  end, "YankChangeId")

  map(view_buf, "<leader>e", function() panel_mod.focus(session.panel) end, "FocusHistoryPanel")
  map(panel_buf, "<leader>e", function() view_mod.focus(session.view) end, "FocusAnnotate")
end

---Open annotate view for a path, with file history panel at the bottom.
---@param root string
---@param opts? { path?: string, line?: integer, revision?: string }
function M.open(root, opts)
  opts = opts or {}
  require("jujutsu.hl").setup()

  local path = opts.path
  if not path or path == "" then
    notify.warn("annotate requires a file path")
    return
  end

  if instance then close_view() end

  local acfg = cfg()
  local panel_height = acfg.panel_height
    or (config.values.file_history and config.values.file_history.panel_height)
    or 16
  local limit = (config.values.file_history and config.values.file_history.limit) or 200

  local ann_lines, err = view_mod.fetch(root, path, opts.revision)
  if err then
    notify.error(err)
    return
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local view_win = vim.api.nvim_get_current_win()

  vim.cmd("botright split")
  local panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(panel_win, panel_height)

  local view = view_mod.create(root, view_win, path)
  local panel = panel_mod.create(root, panel_win, path, "jujutsu://annotate/panel/" .. path)

  instance = {
    root = root,
    path = path,
    tabpage = tabpage,
    view = view,
    panel = panel,
    closing = false,
  }

  view.lines = ann_lines
  view.focus_line = opts.line
  view_mod.render(view)

  panel.entries = panel_mod.load_entries(root, limit, path)
  panel_mod.render(panel, #panel.entries)
  bind_keymaps(instance)

  if opts.line then view_mod.goto_line(view, opts.line) end

  -- Pre-select the change that owns the focused line
  if opts.line then
    for _, row in ipairs(ann_lines) do
      if row.line_number == opts.line then
        local idx = panel_mod.find_entry_index(panel.entries, row.change_id, root)
        if idx then select_change(instance, panel.entries[idx]) end
        break
      end
    end
  elseif #panel.entries > 0 then
    panel.selected_change = panel.entries[1].change_id
    panel_mod.render(panel, #panel.entries)
  end

  view_mod.focus(view)

  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("JujutsuAnnotate", { clear = true }),
    callback = function()
      if not instance or instance.closing then return end
      if not vim.api.nvim_tabpage_is_valid(instance.tabpage) then
        instance.closing = true
        view_mod.destroy(instance.view)
        panel_mod.destroy(instance.panel)
        instance = nil
      end
    end,
  })
end

function M.close() close_view() end

---@return boolean
function M.is_open() return instance ~= nil end

return M
