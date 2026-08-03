local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local config = require("jujutsu.config")
local model = require("jujutsu.issue_panel.model")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local remote_mod = require("jujutsu.forge.remote")
local render = require("jujutsu.issue_panel.render")

local M = {}

---@class IssuePanelState
---@field buf Buffer
---@field win integer
---@field root string
---@field remote ForgeRemote
---@field number integer|string
---@field kind "issue"|"pr"
---@field topic ForgeTopic|nil
---@field comments ForgeConversationComment[]
---@field closing boolean

---@type IssuePanelState|nil
local instance = nil
local last_width = nil

---@return table
local function cfg() return config.values.issue_panel or {} end

---@return integer
local function panel_width()
  local c = cfg()
  local cols = vim.o.columns
  local w = c.width or 0.38
  if w > 0 and w < 1 then w = math.floor(cols * w) end
  w = math.floor(w)
  local min_w = c.min_width or 48
  local max_w = c.max_width or 90
  if last_width then w = last_width end
  return math.max(min_w, math.min(max_w, w, cols - 20))
end

---@return boolean
local function render_markdown_enabled()
  local v = cfg().render_markdown
  if v == nil then return true end
  return v and true or false
end

local function paint(state, payload)
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf.bufnr) then return end
  local markdown = render_markdown_enabled()
  local lines, highlights = render.build(payload, { markdown = markdown })
  Buffer.render(state.buf, lines, highlights)
  -- Bodies are plain markdown text; headers keep JujutsuIssue* extmarks.
  -- Start treesitter so all forges get markdown highlighting by default.
  if markdown then
    pcall(vim.treesitter.start, state.buf.bufnr, "markdown")
  else
    pcall(vim.treesitter.stop, state.buf.bufnr)
  end
end

local function close_panel()
  if not instance or instance.closing then return end
  local state = instance
  state.closing = true
  -- Clear before win_close: WinClosed autocmd would otherwise nil `instance`
  -- while we still need state.buf below.
  instance = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    last_width = vim.api.nvim_win_get_width(state.win)
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.buf.bufnr, { force = true })
  end
end

---@param state IssuePanelState
local function fetch_and_render(state)
  paint(state, { loading = true })
  async.void(function()
    local function load()
      local topic, terr = provider.get_topic(state.root, state.number, { kind = state.kind }, state.remote)
      if not topic then
        if
          provider.is_auth_error(terr) and (state.remote.provider == "bitbucket" or state.remote.provider == "forgejo")
        then
          provider.handle_auth_failure(state.remote, function(updated)
            if updated then vim.schedule(function() fetch_and_render(state) end) end
          end)
          return
        end
        if instance == state then paint(state, { error = terr or "Failed to load" }) end
        return
      end
      local comments, cerr = provider.list_comments(state.root, state.number, { kind = state.kind }, state.remote)
      if cerr and provider.is_auth_error(cerr) then
        provider.handle_auth_failure(state.remote, function(updated)
          if updated then vim.schedule(function() fetch_and_render(state) end) end
        end)
        return
      end
      if instance ~= state then return end
      local normalized = model.normalize(topic, comments or {})
      state.topic = normalized.topic
      state.comments = normalized.comments
      state.kind = normalized.topic.kind
      paint(state, { topic = state.topic, comments = state.comments, error = cerr })
    end
    load()
  end)
end

---@param state IssuePanelState
local function compose_comment(state)
  require("jujutsu.review.ui").prompt_comment("Comment on #" .. tostring(state.number), {}, function(body)
    if not body or vim.trim(body) == "" then
      notify.warn("Empty comment not submitted")
      return
    end
    async.void(function()
      local ok, err = provider.post_comment(state.root, state.number, body, { kind = state.kind }, state.remote)
      if not ok then
        if provider.is_auth_error(err) then
          provider.handle_auth_failure(state.remote, function(updated)
            if updated then vim.schedule(function() compose_comment(state) end) end
          end)
          return
        end
        notify.error(err or "Failed to post comment")
        return
      end
      notify.info("Comment posted")
      fetch_and_render(state)
    end)
  end)
end

---@param state IssuePanelState
local function bind_keymaps(state)
  local keys = cfg().keymaps or {}
  local map = function(lhs, rhs, desc)
    if not lhs or lhs == false then return end
    vim.keymap.set("n", lhs, rhs, {
      buffer = state.buf.bufnr,
      silent = true,
      noremap = true,
      desc = "jujutsu issue panel: " .. desc,
    })
  end
  map(keys.close or "q", close_panel, "Close")
  map(keys.refresh or "r", function() fetch_and_render(state) end, "Refresh")
  map(keys.comment or "c", function() compose_comment(state) end, "Comment")
  map(keys.browser or "o", function()
    local url = state.topic and state.topic.url
    if not url or url == "" then url = remote_mod.topic_url(state.remote, state.number, state.kind) end
    remote_mod.open_url(url)
  end, "OpenInBrowser")
end

---@param opts { root: string, remote: ForgeRemote, number: integer|string, kind?: "issue"|"pr" }
local function open_panel(opts)
  if cfg().enabled == false then
    notify.warn("Issue panel is disabled (issue_panel.enabled = false)")
    return
  end
  if instance then close_panel() end

  local buf = Buffer.create(
    string.format("jujutsu://issue/%s/%s", tostring(opts.kind or "pr"), tostring(opts.number)),
    "markdown"
  )
  vim.bo[buf.bufnr].modifiable = false

  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf.bufnr)
  vim.cmd("wincmd L")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, panel_width())
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  buf.winid = win

  instance = {
    buf = buf,
    win = win,
    root = opts.root,
    remote = opts.remote,
    number = opts.number,
    kind = opts.kind or "pr",
    comments = {},
    closing = false,
  }
  bind_keymaps(instance)
  paint(instance, { loading = true })
  fetch_and_render(instance)

  -- Only react when *this* panel window closes - a comment float's WinClosed
  -- would otherwise consume a once=true autocmd and leave a stale instance.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- External close (e.g. :q on the panel). close_panel() already cleared instance.
      if instance and instance.win == win then instance = nil end
    end,
  })
end

---@param opts? { cwd?: string, root?: string, number?: integer|string, kind?: "issue"|"pr", remote?: ForgeRemote }
function M.open(opts)
  opts = opts or {}
  local root = opts.root or opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local rem = opts.remote or remote_mod.detect(root)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end

  local function proceed(number, kind)
    local function go() open_panel({ root = root, remote = rem, number = number, kind = kind }) end
    if rem.provider == "bitbucket" or rem.provider == "forgejo" then
      provider.ensure_auth(rem, function(ok)
        if ok then vim.schedule(go) end
      end)
    else
      go()
    end
  end

  if opts.number then
    proceed(opts.number, opts.kind or "pr")
    return
  end

  vim.ui.select({ "pr", "issue" }, {
    prompt = "Open conversation for",
    format_item = function(item) return item == "pr" and "Pull request / MR" or "Issue" end,
  }, function(kind)
    if not kind then return end
    vim.ui.input({ prompt = string.format("%s number: ", kind == "pr" and "PR/MR" or "Issue") }, function(num)
      if not num or vim.trim(num) == "" then return end
      proceed(vim.trim(num), kind)
    end)
  end)
end

function M.close() close_panel() end

function M.toggle(opts)
  if instance then
    close_panel()
    return
  end
  M.open(opts)
end

function M.refresh()
  if instance then fetch_and_render(instance) end
end

---@return boolean
function M.is_open() return instance ~= nil end

---@return IssuePanelState|nil
function M.instance() return instance end

return M
