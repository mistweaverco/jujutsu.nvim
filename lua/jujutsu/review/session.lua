local comments_mod = require("jujutsu.review.comments")

local M = {}

---@class ReviewSession
---@field id string
---@field root string
---@field remote ForgeRemote|nil
---@field pr table|nil
---@field number integer|nil
---@field title string
---@field left_rev string
---@field right_rev string
---@field comments ReviewComment[]
---@field remote_comments table[] forge comments from the web UI (flat; derived from cache)
---@field remote_comment_cache table<string, table[]> path → remote comments (in-memory)
---@field remote_comments_loaded boolean
---@field remote_comments_fetched_at integer|nil
---@field reviewed_files table<string, boolean>
---@field dirty boolean
---@field submitted boolean

---@param root string
---@param rem ForgeRemote|nil
---@param pr table|nil
---@return string
local function session_key(root, rem, pr)
  local host = rem and rem.host or "local"
  local owner = rem and rem.owner or "none"
  local repo = rem and rem.repo or vim.fn.fnamemodify(root, ":t")
  local num = pr and pr.number or "local"
  return string.format("%s/%s/%s/%s", host, owner, repo, tostring(num))
end

---@param key string
---@return string
local function path_for(key)
  local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "jujutsu", "reviews")
  vim.fn.mkdir(dir, "p")
  local safe = key:gsub("[^%w%._%-/]", "_"):gsub("/", "__")
  return vim.fs.joinpath(dir, safe .. ".json")
end

---@param session ReviewSession
function M.save(session)
  local key = session_key(session.root, session.remote, session.pr)
  local path = path_for(key)
  local data = {
    id = session.id,
    root = session.root,
    number = session.number,
    title = session.title,
    left_rev = session.left_rev,
    right_rev = session.right_rev,
    comments = session.comments,
    reviewed_files = session.reviewed_files,
    submitted = session.submitted,
    remote = session.remote and {
      provider = session.remote.provider,
      host = session.remote.host,
      owner = session.remote.owner,
      repo = session.remote.repo,
    } or nil,
  }
  vim.fn.writefile({ vim.json.encode(data) }, path)
  session.dirty = false
end

---@param root string
---@param rem ForgeRemote|nil
---@param pr table|nil
---@return table|nil
function M.load_disk(root, rem, pr)
  local path = path_for(session_key(root, rem, pr))
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local lines = vim.fn.readfile(path)
  local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(data) ~= "table" then return nil end
  return data
end

---@param opts { root: string, remote?: ForgeRemote, pr?: table, left_rev: string, right_rev: string, title?: string }
---@return ReviewSession
function M.create(opts)
  local disk = M.load_disk(opts.root, opts.remote, opts.pr)
  ---@type ReviewSession
  local session = {
    id = (disk and disk.id) or string.format("rev-%d", vim.uv.hrtime()),
    root = opts.root,
    remote = opts.remote,
    pr = opts.pr,
    number = opts.pr and opts.pr.number or nil,
    title = opts.title or (opts.pr and opts.pr.title) or "review",
    left_rev = opts.left_rev,
    right_rev = opts.right_rev,
    comments = (disk and disk.comments) or {},
    remote_comments = {},
    remote_comment_cache = {},
    remote_comments_loaded = false,
    remote_comments_fetched_at = nil,
    reviewed_files = (disk and disk.reviewed_files) or {},
    dirty = false,
    submitted = (disk and disk.submitted) or false,
  }
  return session
end

---Index a flat remote comment list into the in-memory path cache.
---@param session ReviewSession
---@param comments table[]
function M.set_remote_comments(session, comments)
  comments = comments or {}
  session.remote_comments = comments
  local by_path = {}
  for _, c in ipairs(comments) do
    local path = c.path
    if path and path ~= "" then
      by_path[path] = by_path[path] or {}
      table.insert(by_path[path], c)
    end
  end
  session.remote_comment_cache = by_path
  session.remote_comments_loaded = true
  session.remote_comments_fetched_at = os.time()
end

---Fetch remote review comments from the forge into the in-memory cache.
---@param session ReviewSession
---@return boolean ok
function M.refresh_remote_comments(session)
  if not session.remote or not session.number then
    M.set_remote_comments(session, {})
    return true
  end
  local provider = require("jujutsu.forge.provider")
  local comments = provider.list_review_comments(session.root, session.number, session.remote)
  M.set_remote_comments(session, comments or {})
  return true
end

---Refresh cached remote comments for one file.
---Most forge APIs only list all PR comments; we refresh the shared in-memory
---cache, then callers re-render this file's overlays / filter badges.
---@param session ReviewSession
---@param path string
---@return boolean ok, string|nil err
function M.refresh_remote_comments_for_path(session, path)
  if not path or path == "" then return false, "No file path" end
  local ok = M.refresh_remote_comments(session)
  if not ok then return false, "Failed to refresh remote comments" end
  session.remote_comment_cache = session.remote_comment_cache or {}
  if session.remote_comment_cache[path] == nil then session.remote_comment_cache[path] = {} end
  return true
end

---Load remote comments once; later calls use the in-memory cache.
---@param session ReviewSession
---@return boolean
function M.ensure_remote_comments(session)
  if session.remote_comments_loaded then return true end
  return M.refresh_remote_comments(session)
end

---@param session ReviewSession
---@param path string
---@return table[]
function M.remote_comments_for_path(session, path)
  if not path then return {} end
  local cached = session.remote_comment_cache and session.remote_comment_cache[path]
  return cached or {}
end

---@param session ReviewSession
---@param path string
---@return table[] remote + local comments for overlays on one file
function M.overlay_comments_for_path(session, path)
  local out = {}
  for _, c in ipairs(M.remote_comments_for_path(session, path)) do
    table.insert(out, c)
  end
  for _, c in ipairs(session.comments or {}) do
    if c.path == path then table.insert(out, c) end
  end
  return out
end

---@param session ReviewSession
---@return table[]
function M.all_overlay_comments(session)
  local out = {}
  for _, c in ipairs(session.remote_comments or {}) do
    table.insert(out, c)
  end
  for _, c in ipairs(session.comments or {}) do
    table.insert(out, c)
  end
  return out
end

---Paths that have local and/or remote comments (for the DiffView filter).
---@param session ReviewSession
---@return table<string, boolean>
function M.paths_with_comments(session)
  local paths = {}
  for path, list in pairs(session.remote_comment_cache or {}) do
    if list and #list > 0 then paths[path] = true end
  end
  for _, c in ipairs(session.comments or {}) do
    if c.path and c.path ~= "" then paths[c.path] = true end
  end
  return paths
end

---@param session ReviewSession
---@param comment ReviewComment
function M.add_comment(session, comment)
  table.insert(session.comments, comment)
  session.dirty = true
  M.save(session)
end

---@param session ReviewSession
---@param id string
---@param body string
---@return boolean
function M.update_comment(session, id, body)
  for _, c in ipairs(session.comments) do
    if c.id == id then
      c.body = body
      session.dirty = true
      M.save(session)
      return true
    end
  end
  return false
end

---@param session ReviewSession
---@param id string
---@return boolean
function M.remove_comment(session, id)
  for i, c in ipairs(session.comments) do
    if c.id == id then
      table.remove(session.comments, i)
      session.dirty = true
      M.save(session)
      return true
    end
  end
  return false
end

---@param session ReviewSession
---@param path string
function M.toggle_reviewed(session, path)
  if session.reviewed_files[path] then
    session.reviewed_files[path] = nil
  else
    session.reviewed_files[path] = true
  end
  session.dirty = true
  M.save(session)
end

---@param session ReviewSession
---@return string
function M.markdown(session) return comments_mod.to_markdown(session.comments, session.title) end

---@param session ReviewSession
function M.mark_submitted(session)
  session.submitted = true
  session.dirty = false
  -- clear pending comments after successful submit
  session.comments = {}
  M.save(session)
end

return M
