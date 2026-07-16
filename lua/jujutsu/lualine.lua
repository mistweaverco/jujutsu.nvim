local Process = require("jujutsu.process")
local shell = require("jujutsu.jj.shell")

local M = {}

local CACHE_TTL_MS = 2000

---@class JujutsuLualineCache
---@field root string|nil
---@field fetched_at integer
---@field change_id string
---@field bookmarks string[]
---@field added integer
---@field changed integer
---@field deleted integer

---@type JujutsuLualineCache|nil
local cache = nil
local autocmd_group = nil

local WC_TEMPLATE = table.concat({
  'change_id.short(8) ++ "\\x1f" ++',
  'local_bookmarks.map(|b| b.name()).join(",") ++ "\\x1e"',
}, " ")

local SEP, REC = "\x1f", "\x1e"

local function ensure_autocmds()
  if autocmd_group then return end
  autocmd_group = vim.api.nvim_create_augroup("JujutsuLualine", { clear = true })
  -- Repo-wide status: refresh after writes / cwd / external shell, not on every BufEnter.
  vim.api.nvim_create_autocmd({ "BufWritePost", "DirChanged", "FocusGained", "ShellCmdPost" }, {
    group = autocmd_group,
    callback = function() cache = nil end,
  })
end

---@return string|nil
local function workspace_root()
  local buf = vim.api.nvim_buf_get_name(0)
  local dir = (buf ~= "" and vim.fn.fnamemodify(buf, ":p:h")) or vim.fn.getcwd()
  return require("jujutsu.jj.cli").find_workspace_root(dir)
end

---@param cmd string[]
---@param root string
---@return ProcessResult
local function jj_run(cmd, root)
  return Process.run({
    cmd = cmd,
    cwd = root,
    suppress_console = true,
    on_error = function() return false end,
  })
end

---@param root string
---@return string, string[]
local function fetch_meta(root)
  local jj = shell.resolve_jj()
  local res = jj_run({
    jj,
    "--no-pager",
    "--color=never",
    "--ignore-working-copy",
    "log",
    "-r",
    "@",
    "--no-graph",
    "-n",
    "1",
    "-T",
    WC_TEMPLATE,
  }, root)

  local change_id, bookmarks = "", {}
  local text = table.concat(res.stdout or {}, "\n")
  for rec in (text .. REC):gmatch("(.-)" .. REC) do
    if rec ~= "" then
      local f = vim.split(rec:gsub("\n", ""), SEP, { plain = true })
      if f[1] and f[1] ~= "" then
        change_id = f[1]
        if f[2] and f[2] ~= "" then bookmarks = vim.split(f[2], ",", { plain = true }) end
        break
      end
    end
  end
  return change_id, bookmarks
end

--- Count +/- lines in a git-format diff (gitsigns-compatible for added/removed).
---@param lines string[]
---@return integer, integer, integer
local function count_diff_lines(lines)
  local added, deleted, changed = 0, 0, 0
  local in_hunk = false
  local pending_del, pending_add = 0, 0

  local function flush_hunk_pair()
    -- Overlapping +/- in a hunk ≈ modified lines (gitsigns "changed")
    local mod = math.min(pending_del, pending_add)
    changed = changed + mod
    added = added + (pending_add - mod)
    deleted = deleted + (pending_del - mod)
    pending_del, pending_add = 0, 0
  end

  for _, line in ipairs(lines) do
    if line:match("^@@") then
      flush_hunk_pair()
      in_hunk = true
    elseif in_hunk then
      local first = line:sub(1, 1)
      if first == "+" and not line:match("^%+%+%+") then
        pending_add = pending_add + 1
      elseif first == "-" and not line:match("^%-%-%-") then
        pending_del = pending_del + 1
      elseif first == " " or first == "\\" then
        flush_hunk_pair()
      end
    end
  end
  flush_hunk_pair()
  return added, changed, deleted
end

--- Working-copy line counts for the whole repo (snapshot from disk).
---@param root string
---@return integer, integer, integer
local function fetch_counts(root)
  local jj = shell.resolve_jj()
  local res = jj_run({
    jj,
    "--no-pager",
    "--color=never",
    "diff",
    "--git",
  }, root)
  if res.code ~= 0 then return 0, 0, 0 end
  return count_diff_lines(res.stdout or {})
end

---@param root string
---@return JujutsuLualineCache
local function fetch(root)
  local change_id, bookmarks = fetch_meta(root)
  local added, changed, deleted = fetch_counts(root)

  return {
    root = root,
    fetched_at = vim.uv.now(),
    change_id = change_id,
    bookmarks = bookmarks,
    added = added,
    changed = changed,
    deleted = deleted,
  }
end

---@return JujutsuLualineCache|nil
local function get_cache()
  ensure_autocmds()
  local root = workspace_root()
  if not root then
    cache = nil
    return nil
  end
  if cache and cache.root == root and (vim.uv.now() - cache.fetched_at) < CACHE_TTL_MS then return cache end
  local ok, data = pcall(fetch, root)
  if not ok or not data then
    cache = nil
    return nil
  end
  cache = data
  return cache
end

---@param name string
---@return string|nil
local function hl_fg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then return nil end
  if hl.link then return hl_fg(hl.link) end
  if hl.fg then return string.format("#%06x", hl.fg) end
  return nil
end

---@param name string
---@return fun(): { fg?: string, gui?: string }
local function color_from(name)
  return function()
    local fg = hl_fg(name)
    if fg then return { fg = fg, gui = "bold" } end
    return { gui = "bold" }
  end
end

---@return boolean
function M.available() return workspace_root() ~= nil end

---@return string
function M.rev()
  local data = get_cache()
  if not data or data.change_id == "" then return "" end
  return data.change_id
end

---@return string
function M.bookmark()
  local data = get_cache()
  if not data or #data.bookmarks == 0 then return "" end
  return table.concat(data.bookmarks, " ")
end

---@return string
function M.diff()
  local data = get_cache()
  if not data then return "" end
  local parts = {}
  if data.added > 0 then table.insert(parts, string.format("+%d", data.added)) end
  if data.changed > 0 then table.insert(parts, string.format("~%d", data.changed)) end
  if data.deleted > 0 then table.insert(parts, string.format("-%d", data.deleted)) end
  return table.concat(parts, " ")
end

---@return string
function M.status()
  local parts = {}
  local rev = M.rev()
  local bm = M.bookmark()
  local diff = M.diff()
  if rev ~= "" then table.insert(parts, rev) end
  if bm ~= "" then table.insert(parts, bm) end
  if diff ~= "" then table.insert(parts, diff) end
  return table.concat(parts, " ")
end

---@return table[]
function M.components()
  local function piece(fn, cond, hl)
    return {
      fn,
      cond = cond,
      color = color_from(hl),
      padding = { left = 1, right = 0 },
      separator = "",
    }
  end

  return {
    piece(function() return M.rev() end, function() return M.rev() ~= "" end, "JujutsuLualineRev"),
    piece(function() return M.bookmark() end, function() return M.bookmark() ~= "" end, "JujutsuLualineBookmark"),
    piece(function()
      local data = get_cache()
      return data and data.added > 0 and ("+" .. data.added) or ""
    end, function()
      local data = get_cache()
      return data ~= nil and data.added > 0
    end, "JujutsuLualineAdd"),
    piece(function()
      local data = get_cache()
      return data and data.changed > 0 and ("~" .. data.changed) or ""
    end, function()
      local data = get_cache()
      return data ~= nil and data.changed > 0
    end, "JujutsuLualineChange"),
    piece(function()
      local data = get_cache()
      return data and data.deleted > 0 and ("-" .. data.deleted) or ""
    end, function()
      local data = get_cache()
      return data ~= nil and data.deleted > 0
    end, "JujutsuLualineDelete"),
  }
end

---@return table
function M.component()
  return {
    function() return M.status() end,
    cond = function() return M.status() ~= "" end,
  }
end

--- Prepend jj components before an existing section list.
---@param section? any[]
---@return any[]
function M.prepend(section)
  local out = {}
  for _, c in ipairs(M.components()) do
    out[#out + 1] = c
  end
  for _, c in ipairs(section or {}) do
    out[#out + 1] = c
  end
  return out
end

--- Append jj components after an existing section list.
---@param section? any[]
---@return any[]
function M.append(section)
  local out = {}
  for _, c in ipairs(section or {}) do
    out[#out + 1] = c
  end
  for _, c in ipairs(M.components()) do
    out[#out + 1] = c
  end
  return out
end

function M.refresh() cache = nil end

return M
