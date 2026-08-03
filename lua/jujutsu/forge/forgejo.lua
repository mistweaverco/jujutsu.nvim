local credentials = require("jujutsu.forge.credentials")
local http = require("jujutsu.forge.http")

local M = {}

---@param remote? { host: string }
---@return string|nil, string|nil
local function resolve_token(remote)
  if remote then
    local creds = credentials.resolve(remote)
    if creds and creds.token and creds.token ~= "" then return creds.token, nil end
  end
  return nil, "Missing Forgejo/Codeberg token for host (will prompt on review)"
end

---@param remote? { host: string }
---@return boolean
function M.available(remote)
  if vim.fn.executable("curl") ~= 1 then return false end
  if remote then return credentials.has(remote) end
  return true
end

---@param remote { host: string }
---@return string
local function api_base(remote) return string.format("https://%s/api/v1", remote.host) end

---@param remote { host: string, owner: string, repo: string }
---@param method string
---@param path string
---@param body? table
---@return table|nil, string|nil
local function api(remote, method, path, body)
  local t, auth_err = resolve_token(remote)
  if auth_err or not t then return nil, auth_err or "Forgejo/Codeberg token missing" end
  local url = api_base(remote) .. path
  local headers = {
    Authorization = "token " .. t,
    Accept = "application/json",
    ["Content-Type"] = body and "application/json" or nil,
  }
  local res = http.request(method, url, headers, body and vim.json.encode(body) or nil)
  if res.err then return nil, res.err end
  return res.json or {}, nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
-- luacheck: ignore 631
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[], string|nil
function M.list_prs(_root, remote)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  local data, err =
    api(remote, "GET", string.format("/repos/%s/%s/pulls?state=open&limit=50", remote.owner, remote.repo))
  if err then return {}, err end
  if type(data) ~= "table" then return {}, "invalid PR list response" end
  local out = {}
  for _, pr in ipairs(data) do
    table.insert(out, {
      number = pr.number,
      title = pr.title or "",
      url = pr.html_url or pr.url or "",
      head_ref = (pr.head and pr.head.ref) or "",
      base_ref = (pr.base and pr.base.ref) or "",
      head_sha = (pr.head and pr.head.sha) or "",
      base_sha = (pr.base and pr.base.sha) or "",
    })
  end
  return out, nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@return table|nil, string|nil
function M.get_pr(_root, remote, number)
  if not M.available(remote) then return nil, "Forgejo/Codeberg token missing or curl unavailable" end
  local pr, err =
    api(remote, "GET", string.format("/repos/%s/%s/pulls/%s", remote.owner, remote.repo, tostring(number)))
  if err then return nil, err end
  if type(pr) ~= "table" then return nil, "invalid PR response" end
  return {
    number = pr.number,
    title = pr.title or "",
    url = pr.html_url or "",
    head_ref = (pr.head and pr.head.ref) or "",
    base_ref = (pr.base and pr.base.ref) or "",
    head_sha = (pr.head and pr.head.sha) or "",
    base_sha = (pr.base and pr.base.sha) or "",
    body = pr.body or "",
  }
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
-- luacheck: ignore 631
---@param opts { event?: string, body?: string, commit_id?: string, comments?: { path: string, body: string, line?: integer, side?: string, start_line?: integer }[] }
---@return boolean, string|nil
function M.submit_review(_root, remote, number, opts)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  if opts.event == "DRAFT" then return false, "Draft reviews are GitHub-only" end

  local comments = {}
  for _, c in ipairs(opts.comments or {}) do
    local entry = {
      path = c.path,
      body = c.body,
    }
    if c.line then
      entry.line = c.line
      entry.old_line = c.side == "LEFT" and 0 or nil
      entry.new_line = c.side ~= "LEFT" and c.line or 0
    end
    table.insert(comments, entry)
  end

  local payload = {
    body = opts.body or "",
    comments = comments,
  }
  if opts.commit_id and opts.commit_id ~= "" then payload.commit_id = opts.commit_id end
  local event = opts.event or "COMMENT"
  if event == "APPROVE" then
    payload.event = "APPROVED"
  elseif event == "REQUEST_CHANGES" then
    payload.event = "REQUEST_CHANGES"
  else
    payload.event = "COMMENT"
  end

  local _, err = api(
    remote,
    "POST",
    string.format("/repos/%s/%s/pulls/%s/reviews", remote.owner, remote.repo, tostring(number)),
    payload
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@return ForgeRemoteComment[]
function M.list_review_comments(_, remote, number)
  if not M.available(remote) then return {} end
  local threads = require("jujutsu.review.threads")
  local data, err =
    api(remote, "GET", string.format("/repos/%s/%s/pulls/%s/comments", remote.owner, remote.repo, tostring(number)))
  if err or type(data) ~= "table" then return {} end
  local out = {}
  for _, c in ipairs(data) do
    local line = c.position or c.line or c.new_position or c.new_line or c.old_line
    local path = c.path
    local parent_raw = c.reply_to_comment_id or c.in_reply_to_id or c.in_reply_to
    local parent_id = parent_raw and parent_raw ~= 0 and threads.remote_id(parent_raw) or nil
    if path and line and line ~= 0 then
      local side = "RIGHT"
      if c.old_line and (not c.new_line or c.new_line == 0) then side = "LEFT" end
      table.insert(out, {
        id = threads.remote_id(c.id),
        path = path,
        side = side,
        line = tonumber(line) or line,
        body = c.body or "",
        author = (c.user and (c.user.login or c.user.username)) or "unknown",
        outdated = false,
        url = c.html_url,
        remote = true,
        kind = "line",
        parent_id = parent_id,
        provider = "forgejo",
        created_at = c.created_at,
        updated_at = c.updated_at,
        supports_reply = true,
      })
    elseif parent_id then
      table.insert(out, {
        id = threads.remote_id(c.id),
        path = path,
        side = "RIGHT",
        line = (line and line ~= 0) and (tonumber(line) or line) or nil,
        body = c.body or "",
        author = (c.user and (c.user.login or c.user.username)) or "unknown",
        outdated = false,
        url = c.html_url,
        remote = true,
        kind = "line",
        parent_id = parent_id,
        provider = "forgejo",
        created_at = c.created_at,
        updated_at = c.updated_at,
        supports_reply = true,
      })
    end
  end
  threads.inherit_locations(out)
  local filtered = {}
  for _, c in ipairs(out) do
    if c.path and c.line then table.insert(filtered, c) end
  end
  return filtered
end

---@param labels any
---@return string[]
local function map_labels(labels)
  local out = {}
  if type(labels) ~= "table" then return out end
  for _, l in ipairs(labels) do
    if type(l) == "string" then
      table.insert(out, l)
    elseif type(l) == "table" then
      table.insert(out, l.name or l.title or tostring(l.id or "?"))
    end
  end
  return out
end

---@param users any
---@return string[]
local function map_users(users)
  local out = {}
  if type(users) ~= "table" then return out end
  for _, u in ipairs(users) do
    if type(u) == "table" then table.insert(out, u.login or u.username or u.full_name or tostring(u.id or "?")) end
  end
  return out
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@return ForgeTopic|nil, string|nil
function M.get_topic(_, remote, number, opts)
  if not M.available(remote) then return nil, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  local kind = opts.kind or "issue"
  local issue, err =
    api(remote, "GET", string.format("/repos/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number)))
  if err or type(issue) ~= "table" then return nil, err or "failed to fetch issue" end

  local state = issue.state or "open"
  local draft, merged = false, false
  local is_pr = issue.pull_request ~= nil or kind == "pr"
  if is_pr then
    kind = "pr"
    local pr =
      select(1, api(remote, "GET", string.format("/repos/%s/%s/pulls/%s", remote.owner, remote.repo, tostring(number))))
    if type(pr) == "table" then
      draft = pr.draft == true
      merged = pr.merged == true or (type(pr.merged_at) == "string" and pr.merged_at ~= "")
      if pr.merged == true or (type(pr.merged_at) == "string" and pr.merged_at ~= "") then
        state = "merged"
        merged = true
      elseif draft then
        state = "draft"
      else
        state = pr.state or state
      end
    end
  else
    kind = "issue"
  end

  return {
    kind = kind,
    number = issue.number or number,
    title = issue.title or "",
    body = issue.body or "",
    state = state,
    draft = draft,
    merged = merged,
    author = (issue.user and (issue.user.login or issue.user.username)) or "unknown",
    created_at = issue.created_at,
    updated_at = issue.updated_at,
    labels = map_labels(issue.labels),
    assignees = map_users(issue.assignees),
    url = issue.html_url or "",
    repo = remote.owner .. "/" .. remote.repo,
  }
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@param _opts? { kind?: "issue"|"pr" }
---@return ForgeConversationComment[], string|nil
function M.list_comments(_root, remote, number, _opts)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  local data, err =
    api(remote, "GET", string.format("/repos/%s/%s/issues/%s/comments", remote.owner, remote.repo, tostring(number)))
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  local out = {}
  for _, c in ipairs(data) do
    table.insert(out, {
      id = tostring(c.id),
      author = (c.user and (c.user.login or c.user.username)) or "unknown",
      created_at = c.created_at,
      updated_at = c.updated_at,
      body = c.body or "",
      url = c.html_url,
      kind = "comment",
    })
  end
  return out, nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@param body string
---@param _opts? { kind?: "issue"|"pr" }
---@return boolean, string|nil
function M.post_comment(_root, remote, number, body, _opts)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local _, err = api(
    remote,
    "POST",
    string.format("/repos/%s/%s/issues/%s/comments", remote.owner, remote.repo, tostring(number)),
    { body = body }
  )
  if err then return false, err end
  return true
end

---Reply to a pull review comment (`reply_to_comment_id`).
---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@param opts { parent_id: string|integer, body: string }
---@return boolean, string|nil
function M.post_reply(_root, remote, number, opts)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  local body = opts.body
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local threads = require("jujutsu.review.threads")
  local parent = tonumber(threads.raw_id(opts.parent_id))
  if not parent then return false, "Missing parent comment id" end
  local _, err = api(
    remote,
    "POST",
    string.format("/repos/%s/%s/pulls/%s/comments", remote.owner, remote.repo, tostring(number)),
    { body = body, reply_to_comment_id = parent }
  )
  if err then return false, err end
  return true
end

return M
