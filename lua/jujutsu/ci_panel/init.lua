local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local config = require("jujutsu.config")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local remote_mod = require("jujutsu.forge.remote")
local render = require("jujutsu.ci_panel.render")

local M = {}

---@class CiPanelState
---@field buf Buffer
---@field win integer
---@field root string
---@field remote ForgeRemote
---@field view "list"|"run"|"job"|"logs"
---@field runs ForgeCiRun[]
---@field run_detail? ForgeCiRunDetail
---@field job_detail? ForgeCiJobDetail
---@field selected_run? ForgeCiRun
---@field selected_job? ForgeCiJob
---@field log_lines? string[]
---@field item_ranges table[]
---@field list_limit integer
---@field list_has_more boolean
---@field list_loading boolean
---@field closing boolean

---@type CiPanelState|nil
local instance = nil
local last_width = nil

---@return table
local function cfg() return config.values.ci_panel or {} end

---@return integer
local function panel_width()
  local c = cfg()
  local cols = vim.o.columns
  local w = c.width or 0.55
  if w > 0 and w < 1 then w = math.floor(cols * w) end
  w = math.floor(w)
  local min_w = c.min_width or 72
  local max_w = c.max_width or 160
  if last_width then w = last_width end
  return math.max(min_w, math.min(max_w, w, cols - 16))
end

---@param state CiPanelState
---@param lines string[]
---@param highlights? table[]
---@param meta? table
local function paint(state, lines, highlights, meta)
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf.bufnr) then return end
  state.item_ranges = (meta and meta.item_ranges) or {}
  Buffer.render(state.buf, lines, highlights)
end

local function close_panel()
  if not instance or instance.closing then return end
  local state = instance
  state.closing = true
  instance = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    last_width = vim.api.nvim_win_get_width(state.win)
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.buf.bufnr, { force = true })
  end
end

---@param state CiPanelState
---@return table|nil
local function item_under_cursor(state)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1
  for _, range in ipairs(state.item_ranges or {}) do
    if row >= range.start_line and row <= range.end_line then return range end
  end
  return nil
end

---@param state CiPanelState
---@return ForgeCiRun|nil
local function run_at_cursor(state)
  if state.view ~= "list" then return nil end
  local item = item_under_cursor(state)
  if item and item.run then return item.run end
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1
  for _, range in ipairs(state.item_ranges or {}) do
    if range.kind == "run" and row >= range.start_line and row <= range.end_line then return range.run end
  end
  return nil
end

---@param state CiPanelState
---@return string|nil
local function browser_url(state)
  if state.view == "list" then
    local run = run_at_cursor(state)
    if run and run.url and run.url ~= "" then return run.url end
  end
  if state.view == "job" and state.job_detail and state.job_detail.job.url and state.job_detail.job.url ~= "" then
    return state.job_detail.job.url
  end
  if state.view == "run" and state.run_detail and state.run_detail.run.url and state.run_detail.run.url ~= "" then
    return state.run_detail.run.url
  end
  if state.selected_run and state.selected_run.url and state.selected_run.url ~= "" then
    return state.selected_run.url
  end
  return nil
end

---@param state CiPanelState
---@param err string
---@param retry fun()
---@return boolean handled
local function handle_load_error(state, err, retry)
  if provider.is_scope_error(err) then
    local lines, hls = render.build_error(err)
    paint(state, lines, hls)
    return true
  end
  if provider.is_auth_error(err) then
    provider.handle_auth_failure(state.remote, function(updated)
      if updated then vim.schedule(retry) end
    end)
    return true
  end
  return false
end

---@return integer
local function page_size() return cfg().page_size or 20 end

---@param state CiPanelState
local function paint_list(state)
  local lines, hls, meta = render.build_list(state.runs, state.remote, {
    has_more = state.list_has_more,
    list_limit = state.list_limit,
  })
  paint(state, lines, hls, meta)
end

---@param state CiPanelState
---@param opts? { reset?: boolean }
local function load_list(state, opts)
  opts = opts or {}
  if opts.reset or not state.list_limit then state.list_limit = page_size() end
  state.view = "list"
  state.list_loading = true
  paint(state, render.build_loading("Loading CI runs…"))
  async.void(function()
    local runs, err, meta = provider.list_ci_runs(state.root, { limit = state.list_limit }, state.remote)
    if instance ~= state then return end
    state.list_loading = false
    if err then
      if handle_load_error(state, err, function() load_list(state, opts) end) then return end
      local lines, hls = render.build_error(err)
      paint(state, lines, hls)
      return
    end
    state.runs = runs or {}
    state.list_has_more = meta and meta.has_more == true or false
    paint_list(state)
  end)
end

---@param state CiPanelState
local function load_more_list(state)
  if state.view ~= "list" or state.list_loading or not state.list_has_more then return end
  state.list_limit = state.list_limit * 2
  load_list(state)
end

---@param state CiPanelState
---@param run ForgeCiRun
local function load_run(state, run)
  state.view = "run"
  state.selected_run = run
  state.run_detail = nil
  state.job_detail = nil
  paint(state, render.build_loading("Loading run " .. tostring(run.id) .. "…"))
  async.void(function()
    local detail, err = provider.get_ci_run(state.root, run.id, state.remote)
    if instance ~= state then return end
    if err then
      if handle_load_error(state, err, function() load_run(state, run) end) then return end
      local lines, hls = render.build_error(err)
      paint(state, lines, hls)
      return
    end
    state.run_detail = detail
    state.selected_run = detail.run
    local lines, hls, meta = render.build_run(detail)
    paint(state, lines, hls, meta)
  end)
end

---@param state CiPanelState
---@param run ForgeCiRun
---@param job ForgeCiJob
local function load_job(state, run, job)
  state.view = "job"
  state.selected_run = run
  state.selected_job = job
  state.job_detail = nil
  paint(state, render.build_loading("Loading job " .. tostring(job.id) .. "…"))
  async.void(function()
    local detail, err = provider.get_ci_job(state.root, run.id, job.id, state.remote)
    if instance ~= state then return end
    if err then
      if handle_load_error(state, err, function() load_job(state, run, job) end) then return end
      local lines, hls = render.build_error(err)
      paint(state, lines, hls)
      return
    end
    state.job_detail = detail
    state.selected_job = detail.job
    local caps = provider.capabilities(state.remote)
    local lines, hls, meta = render.build_job(detail, caps)
    paint(state, lines, hls, meta)
  end)
end

---@param state CiPanelState
local function load_logs(state)
  local caps = provider.capabilities(state.remote)
  if not caps.ci.logs then
    notify.warn("Logs not supported for " .. state.remote.provider)
    return
  end
  local run = state.selected_run
  local job = state.selected_job
  if state.view == "run" then
    local item = item_under_cursor(state)
    if item and item.kind == "job" then
      run = item.run or run
      job = item.job
    end
  end
  if not run or not job then
    notify.warn("Select a job first")
    return
  end
  state.selected_run = run
  state.selected_job = job
  state.view = "logs"
  paint(state, render.build_loading("Loading logs…"))
  async.void(function()
    local lines, err = provider.get_ci_job_logs(state.root, run.id, job.id, state.remote)
    if instance ~= state then return end
    if err then
      if handle_load_error(state, err, function() load_logs(state) end) then return end
      local elines, hls = render.build_error(err)
      paint(state, elines, hls)
      return
    end
    state.log_lines = lines
    local rendered, hls = render.build_logs(job, lines)
    paint(state, rendered, hls)
  end)
end

---@param state CiPanelState
local function go_back(state)
  if state.view == "logs" then
    if state.job_detail and state.selected_run and state.selected_job then
      load_job(state, state.selected_run, state.selected_job)
    elseif state.selected_run then
      load_run(state, state.selected_run)
    else
      load_list(state)
    end
    return
  end
  if state.view == "job" then
    if state.selected_run then
      load_run(state, state.selected_run)
    else
      load_list(state)
    end
    return
  end
  if state.view == "run" then
    load_list(state, { reset = false })
    return
  end
  close_panel()
end

---@param state CiPanelState
local function refresh(state)
  if state.view == "logs" then
    load_logs(state)
  elseif state.view == "job" and state.selected_run and state.selected_job then
    load_job(state, state.selected_run, state.selected_job)
  elseif state.view == "run" and state.selected_run then
    load_run(state, state.selected_run)
  elseif state.view == "list" then
    load_list(state, { reset = false })
  else
    load_list(state, { reset = true })
  end
end

---@param state CiPanelState
local function open_selection(state)
  local item = item_under_cursor(state)
  if state.view == "list" then
    if item and item.kind == "load_more" then
      load_more_list(state)
      return
    end
    local run = item and item.run or run_at_cursor(state)
    if run then load_run(state, run) end
    return
  end
  if state.view == "run" then
    local job = item and item.job
    local run = (item and item.run) or state.selected_run
    if job and run then load_job(state, run, job) end
    return
  end
end

---@param state CiPanelState
local function cancel_run(state)
  local run = state.selected_run or (state.run_detail and state.run_detail.run)
  if not run then
    notify.warn("No run selected")
    return
  end
  if not run.can_cancel then
    notify.warn("This run cannot be cancelled")
    return
  end
  async.void(function()
    local ok, err = provider.cancel_ci_run(state.root, run.id, state.remote)
    if not ok then
      notify.error(err or "Failed to cancel")
      return
    end
    notify.info("CI run cancelled")
    refresh(state)
  end)
end

---@param state CiPanelState
local function bind_keymaps(state)
  local keys = cfg().keymaps or {}
  local map = function(lhs, rhs, desc)
    if not lhs or lhs == false then return end
    vim.keymap.set("n", lhs, rhs, {
      buffer = state.buf.bufnr,
      silent = true,
      noremap = true,
      desc = "jujutsu ci panel: " .. desc,
    })
  end
  map(keys.close or "q", function()
    if state.view == "list" then
      close_panel()
    else
      go_back(state)
    end
  end, "CloseOrBack")
  map(keys.back or "<bs>", function() go_back(state) end, "Back")
  map(keys.refresh or "r", function() refresh(state) end, "Refresh")
  map(keys.open or "<cr>", function() open_selection(state) end, "Open")
  map(keys.browser or "o", function()
    local url = browser_url(state)
    if url and url ~= "" then
      remote_mod.open_url(url)
    else
      notify.warn("No URL for this view")
    end
  end, "OpenInBrowser")
  map(keys.logs or "l", function() load_logs(state) end, "Logs")
  map(keys.cancel or "x", function() cancel_run(state) end, "Cancel")
  map(keys.load_more or "+", function() load_more_list(state) end, "LoadMore")
end

---@param opts { root: string, remote: ForgeRemote }
local function open_panel(opts)
  if cfg().enabled == false then
    notify.warn("CI panel is disabled (ci_panel.enabled = false)")
    return
  end
  if instance then close_panel() end

  local buf = Buffer.create("jujutsu://ci", "jujutsu-ci")
  vim.bo[buf.bufnr].modifiable = false

  vim.cmd("botright vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, buf.bufnr)
  vim.cmd("wincmd L")
  Buffer.focus(buf)
  panel_win = buf.winid or panel_win
  vim.api.nvim_win_set_width(panel_win, panel_width())
  vim.wo[panel_win].wrap = false
  vim.wo[panel_win].number = false
  vim.wo[panel_win].relativenumber = false
  vim.wo[panel_win].signcolumn = "no"
  vim.wo[panel_win].cursorline = true
  buf.winid = panel_win
  local win = panel_win

  instance = {
    buf = buf,
    win = win,
    root = opts.root,
    remote = opts.remote,
    view = "list",
    runs = {},
    item_ranges = {},
    list_limit = page_size(),
    list_has_more = false,
    list_loading = false,
    closing = false,
  }
  bind_keymaps(instance)
  load_list(instance, { reset = true })
  Buffer.focus(buf)
  vim.schedule(function()
    if instance and instance.buf.bufnr == buf.bufnr then Buffer.focus(buf) end
  end)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if instance and instance.win == win then instance = nil end
    end,
  })
end

---@param opts? { cwd?: string, root?: string, remote?: ForgeRemote }
function M.open(opts)
  opts = opts or {}
  local root = opts.root or opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local rem = opts.remote or remote_mod.detect(root)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  local caps = provider.capabilities(rem)
  if not caps.ci.list then
    notify.error("CI listing not supported for " .. rem.provider)
    return
  end

  local function go()
    if instance and Buffer.is_open(instance.buf) then
      Buffer.focus(instance.buf)
      refresh(instance)
      return
    end
    open_panel({ root = root, remote = rem })
  end
  if rem.provider == "bitbucket" or rem.provider == "forgejo" then
    provider.ensure_auth(rem, function(ok)
      if ok then vim.schedule(go) end
    end)
  else
    go()
  end
end

function M.close() close_panel() end

function M.refresh()
  if instance then refresh(instance) end
end

---@return boolean
function M.is_open() return instance ~= nil end

return M
