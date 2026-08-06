local cache = require("jujutsu.forge.cache")
local credentials = require("jujutsu.forge.credentials")
local http = require("jujutsu.forge.http")
local labels_mod = require("jujutsu.forge.labels")

local M = {}

---@return ForgeCapabilities
function M.capabilities()
  return {
    prs = {
      list = true,
      search = true,
      create = true,
      update = true,
      close = true,
      merge = true,
      draft = true,
      labels = true,
      assignees = true,
      multi_assignees = true,
    },
    issues = {
      list = true,
      search = true,
      create = true,
      update = true,
      close = true,
      labels = true,
      assignees = true,
      multi_assignees = true,
    },
    comments = { list = true, create = true, update = true, delete = true },
    ci = { list = true, cancel = true, trigger = true, view = true, logs = true },
  }
end

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
local function api_request(remote, method, path, body)
  local t, auth_err = resolve_token(remote)
  if auth_err or not t then return nil, auth_err or "Forgejo/Codeberg token missing" end
  local url = api_base(remote) .. path
  local headers = {
    Authorization = "token " .. t,
    Accept = "application/json",
    ["Content-Type"] = body and "application/json" or nil,
  }
  local res = http.request(method, url, headers, body and http.encode_json(body) or nil)
  if res.err then return nil, res.err end
  return res.json or {}, nil
end

---@param remote { host: string, owner: string, repo: string }
---@param method string
---@param path string
---@param body? table
---@return table|nil, string|nil
local function api(remote, method, path, body)
  if not cache.is_http_read(method) then
    local result, err = api_request(remote, method, path, body)
    if result and not err then cache.clear() end
    return result, err
  end
  local body_key = body and http.encode_json(body) or ""
  local cache_key = cache.key("forgejo", remote.host, remote.owner, remote.repo, method, path, body_key)
  return cache.fetch(cache_key, function() return api_request(remote, method, path, body) end)
end

---@param remote { host: string, owner: string, repo: string }
---@param path string
---@return string|nil, string|nil
local function api_text_request(remote, path)
  local t, auth_err = resolve_token(remote)
  if auth_err or not t then return nil, auth_err or "Forgejo/Codeberg token missing" end
  local url = api_base(remote) .. path
  local headers = {
    Authorization = "token " .. t,
    Accept = "text/plain",
  }
  local res = http.request("GET", url, headers)
  if res.err then return nil, res.err end
  return res.body or "", nil
end

---@param remote { host: string, owner: string, repo: string }
---@param path string
---@return string|nil, string|nil
local function api_text(remote, path)
  local cache_key = cache.key("forgejo-text", remote.host, remote.owner, remote.repo, path)
  return cache.fetch(cache_key, function() return api_text_request(remote, path) end)
end

---@param r table
---@return ForgeCiRun
local function map_run(r)
  local status = r.status or r.state or ""
  local can_cancel = status == "queued" or status == "running" or status == "in_progress" or status == "waiting"
  return {
    id = tostring(r.id),
    name = r.display_title or r.name or r.title or ("run " .. tostring(r.id)),
    title = r.display_title or r.name or r.title,
    workflow = r.name or "Workflow",
    event = r.event,
    status = status,
    conclusion = r.conclusion,
    url = r.html_url or r.url,
    can_cancel = can_cancel,
    branch = r.head_branch or r.ref,
    head_sha = r.head_sha or r.commit_sha,
    created_at = r.created_at,
    updated_at = r.updated_at,
    started_at = r.run_started_at or r.created_at,
    elapsed = "",
  }
end

---@param j table
---@return ForgeCiJob
local function map_job(j)
  local steps = {}
  for _, s in ipairs(j.steps or {}) do
    table.insert(steps, {
      name = s.name or "?",
      status = s.status or "",
      conclusion = s.conclusion,
      number = s.number,
    })
  end
  return {
    id = tostring(j.id),
    name = j.name or ("job " .. tostring(j.id)),
    status = j.status or "",
    conclusion = j.conclusion,
    url = j.html_url or j.url,
    elapsed = "",
    steps = steps,
  }
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
    local line = threads.as_line(c.position)
      or threads.as_line(c.line)
      or threads.as_line(c.new_position)
      or threads.as_line(c.new_line)
      or threads.as_line(c.old_line)
    local path = c.path
    local parent_raw = c.reply_to_comment_id or c.in_reply_to_id or c.in_reply_to
    local parent_id = parent_raw and parent_raw ~= 0 and parent_raw ~= vim.NIL and threads.remote_id(parent_raw) or nil
    if path and line and line ~= 0 then
      local side = "RIGHT"
      if threads.as_line(c.old_line) and not threads.as_line(c.new_line) then side = "LEFT" end
      table.insert(out, {
        id = threads.remote_id(c.id),
        path = path,
        side = side,
        line = line,
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
        line = (line and line ~= 0) and line or nil,
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
    if c.path and threads.as_line(c.line) then table.insert(filtered, c) end
  end
  return filtered
end

---@param labels any
---@return ForgeLabel[]
local function map_labels(labels) return labels_mod.map(labels, { github = true }) end

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

---@param s string
---@return string
local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param filter? ForgeSearchFilter
---@return table[], string|nil
function M.search_prs(_root, remote, filter)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  filter = filter or {}
  local state = filter.state or "open"
  if state == "all" then state = "all" end
  local path = string.format(
    "/repos/%s/%s/pulls?state=%s&limit=%s",
    remote.owner,
    remote.repo,
    state,
    tostring(filter.limit or 50)
  )
  local data, err = api(remote, "GET", path)
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  local out = {}
  for _, pr in ipairs(data) do
    local draft = pr.draft == true
    if filter.draft == true and not draft then goto continue end
    if filter.draft == false and draft then goto continue end
    if filter.query and filter.query ~= "" then
      local hay = string.lower((pr.title or "") .. " " .. (pr.body or ""))
      if not hay:find(string.lower(filter.query), 1, true) then goto continue end
    end
    table.insert(out, {
      number = pr.number,
      title = pr.title or "",
      url = pr.html_url or "",
      head_ref = (pr.head and pr.head.ref) or "",
      base_ref = (pr.base and pr.base.ref) or "",
      head_sha = (pr.head and pr.head.sha) or "",
      base_sha = (pr.base and pr.base.sha) or "",
      draft = draft,
      state = pr.state or "open",
      kind = "pr",
    })
    ::continue::
  end
  return out, nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param opts { title: string, body?: string, head?: string, base?: string, draft?: boolean, labels?: string[] }
---@return table|nil, string|nil
function M.create_pr(_root, remote, opts)
  if not M.available(remote) then return nil, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  if not opts.title or opts.title == "" then return nil, "Title required" end
  if not opts.head or opts.head == "" then return nil, "head branch required" end
  local payload = {
    title = opts.title,
    body = opts.body or "",
    head = opts.head,
    base = opts.base or "main",
  }
  if opts.draft ~= nil then payload.draft = opts.draft end
  local pr, err = api(remote, "POST", string.format("/repos/%s/%s/pulls", remote.owner, remote.repo), payload)
  if err or type(pr) ~= "table" then return nil, err or "failed to create PR" end
  if opts.labels and #opts.labels > 0 and pr.number then
    api(
      remote,
      "PATCH",
      string.format("/repos/%s/%s/issues/%s", remote.owner, remote.repo, tostring(pr.number)),
      { labels = opts.labels }
    )
  end
  return {
    number = pr.number,
    title = pr.title or opts.title,
    url = pr.html_url or "",
    head_ref = opts.head,
    base_ref = opts.base or "main",
  },
    nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@param opts { title?: string, body?: string, base?: string, draft?: boolean, labels?: string[], assignees?: string[] }
---@return boolean, string|nil
function M.update_pr(_root, remote, number, opts)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  local payload = {}
  if opts.title then payload.title = opts.title end
  if opts.body ~= nil then payload.body = opts.body end
  if opts.base then payload.base = opts.base end
  if opts.draft ~= nil then payload.draft = opts.draft end
  if next(payload) then
    local _, err =
      api(remote, "PATCH", string.format("/repos/%s/%s/pulls/%s", remote.owner, remote.repo, tostring(number)), payload)
    if err then return false, err end
  end
  if opts.labels or opts.assignees then
    local issue_payload = {}
    if opts.labels then issue_payload.labels = opts.labels end
    if opts.assignees then issue_payload.assignees = opts.assignees end
    local _, err = api(
      remote,
      "PATCH",
      string.format("/repos/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number)),
      issue_payload
    )
    if err then return false, err end
  end
  return true
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@return boolean, string|nil
function M.close_pr(_root, remote, number)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  local _, err = api(
    remote,
    "PATCH",
    string.format("/repos/%s/%s/pulls/%s", remote.owner, remote.repo, tostring(number)),
    { state = "closed" }
  )
  if err then return false, err end
  return true
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@param opts? { method?: string }
---@return boolean, string|nil
function M.merge_pr(_root, remote, number, opts)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  local style = "merge"
  if opts.method == "squash" then
    style = "squash"
  elseif opts.method == "rebase" then
    style = "rebase"
  end
  local _, err = api(
    remote,
    "POST",
    string.format("/repos/%s/%s/pulls/%s/merge", remote.owner, remote.repo, tostring(number)),
    { Do = style }
  )
  if err then return false, err end
  return true
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@return ForgeLabel[], string|nil
function M.list_repo_labels(_root, remote)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  local data, err = api(remote, "GET", string.format("/repos/%s/%s/labels", remote.owner, remote.repo))
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  return map_labels(data), nil
end

---@param users any
---@return ForgeUser[]
local function map_assignable_users(users)
  local out = {}
  if type(users) ~= "table" then return out end
  for _, u in ipairs(users) do
    local login = u.login or u.username
    if type(u) == "table" and login and login ~= "" then
      table.insert(out, { login = login, name = u.full_name or u.name, id = u.id })
    end
  end
  return out
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@return ForgeUser[], string|nil
function M.list_assignable_users(_root, remote)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  local data, err = api(remote, "GET", string.format("/repos/%s/%s/assignees", remote.owner, remote.repo))
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  return map_assignable_users(data), nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param filter? ForgeSearchFilter
---@return table[], string|nil
function M.search_issues(_root, remote, filter)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  filter = filter or {}
  local state = filter.state or "open"
  local path = string.format(
    "/repos/%s/%s/issues?state=%s&type=issues&limit=%s",
    remote.owner,
    remote.repo,
    state,
    tostring(filter.limit or 50)
  )
  -- Forgejo has no @me
  if filter.assignee ~= "@me" and filter.assignee and filter.assignee ~= "" then
    path = path .. "&assigned_by=" .. urlencode(filter.assignee)
  end
  if filter.label and filter.label ~= "" then path = path .. "&labels=" .. urlencode(filter.label) end
  if filter.query and filter.query ~= "" then path = path .. "&q=" .. urlencode(filter.query) end
  local data, err = api(remote, "GET", path)
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  local out = {}
  for _, issue in ipairs(data) do
    if not issue.pull_request then
      table.insert(out, {
        number = issue.number,
        title = issue.title or "",
        url = issue.html_url or "",
        state = issue.state or "open",
        labels = map_labels(issue.labels),
        kind = "issue",
        author = (issue.user and (issue.user.login or issue.user.username)) or "",
      })
    end
  end
  return out, nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param opts { title: string, body?: string, labels?: string[] }
---@return table|nil, string|nil
function M.create_issue(_root, remote, opts)
  if not M.available(remote) then return nil, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  if not opts.title or opts.title == "" then return nil, "Title required" end
  local payload = { title = opts.title, body = opts.body or "" }
  if opts.labels then payload.labels = opts.labels end
  local issue, err = api(remote, "POST", string.format("/repos/%s/%s/issues", remote.owner, remote.repo), payload)
  if err or type(issue) ~= "table" then return nil, err or "failed to create issue" end
  return {
    number = issue.number,
    title = issue.title or opts.title,
    url = issue.html_url or "",
    kind = "issue",
  },
    nil
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@param opts { title?: string, body?: string, labels?: string[], assignees?: string[], state?: string }
---@return boolean, string|nil
function M.update_issue(_root, remote, number, opts)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  local payload = {}
  if opts.title then payload.title = opts.title end
  if opts.body ~= nil then payload.body = opts.body end
  if opts.labels then payload.labels = opts.labels end
  if opts.assignees then payload.assignees = opts.assignees end
  if opts.state then payload.state = opts.state end
  local _, err =
    api(remote, "PATCH", string.format("/repos/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number)), payload)
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@return boolean, string|nil
function M.close_issue(_, remote, number) return M.update_issue(_, remote, number, { state = "closed" }) end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param _ integer|string
---@param comment_id string|integer
---@param body string
---@return boolean, string|nil
function M.update_comment(_, remote, _, comment_id, body)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local _, err = api(
    remote,
    "PATCH",
    string.format("/repos/%s/%s/issues/comments/%s", remote.owner, remote.repo, tostring(comment_id)),
    { body = body }
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param _ integer|string
---@param comment_id string|integer
---@return boolean, string|nil
function M.delete_comment(_, remote, _, comment_id)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  local _, err = api(
    remote,
    "DELETE",
    string.format("/repos/%s/%s/issues/comments/%s", remote.owner, remote.repo, tostring(comment_id))
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param opts? { branch?: string, limit?: integer }
---@return ForgeCiRun[], string|nil, ForgeCiListMeta|nil
function M.list_ci_runs(_, remote, opts)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  local limit = opts.limit or 20
  local path = string.format("/repos/%s/%s/actions/runs?limit=%s", remote.owner, remote.repo, tostring(limit))
  local data, err = api(remote, "GET", path)
  if err then
    -- Older Forgejo may lack Actions; degrade gracefully
    return {}, nil, { has_more = false }
  end
  local runs = {}
  if type(data) == "table" then
    if data.workflow_runs then
      runs = data.workflow_runs
    elseif data[1] then
      runs = data
    end
  end
  local out = {}
  for _, r in ipairs(runs) do
    table.insert(out, map_run(r))
  end
  return out, nil, { has_more = #out >= limit }
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param run_id string|integer
---@return boolean, string|nil
function M.cancel_ci_run(_, remote, run_id)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  local _, err = api(
    remote,
    "POST",
    string.format("/repos/%s/%s/actions/runs/%s/cancel", remote.owner, remote.repo, tostring(run_id))
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@return ForgeWorkflow[], string|nil
function M.list_triggerable_workflows(_, remote)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  local data, err = api(remote, "GET", string.format("/repos/%s/%s/actions/workflows", remote.owner, remote.repo))
  if err or type(data) ~= "table" then return {}, nil end
  local workflows = data.workflows or data
  local out = {}
  if type(workflows) ~= "table" then return {}, nil end
  for _, w in ipairs(workflows) do
    table.insert(out, {
      id = tostring(w.id or w.name),
      name = w.name or w.path or tostring(w.id),
      path = w.path,
      can_dispatch = true,
    })
  end
  return out, nil
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param opts { workflow_id: string|integer, ref?: string, inputs?: table }
---@return boolean, string|nil
function M.trigger_ci(_, remote, opts)
  if not M.available(remote) then return false, "Forgejo/Codeberg token missing or curl unavailable" end
  opts = opts or {}
  if not opts.workflow_id then return false, "workflow_id required" end
  local ref = opts.ref or "main"
  local _, err = api(
    remote,
    "POST",
    string.format("/repos/%s/%s/actions/workflows/%s/dispatches", remote.owner, remote.repo, tostring(opts.workflow_id)),
    { ref = ref, inputs = opts.inputs or {} }
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param run_id string|integer
---@return ForgeCiRunDetail|nil, string|nil
function M.get_ci_run(_, remote, run_id)
  if not M.available(remote) then return nil, "Forgejo/Codeberg token missing or curl unavailable" end
  local run_data, err =
    api(remote, "GET", string.format("/repos/%s/%s/actions/runs/%s", remote.owner, remote.repo, tostring(run_id)))
  if err then return nil, err end
  local jobs_data, jerr =
    api(remote, "GET", string.format("/repos/%s/%s/actions/runs/%s/jobs", remote.owner, remote.repo, tostring(run_id)))
  if jerr then return nil, jerr end
  local jobs = {}
  local job_list = (type(jobs_data) == "table" and (jobs_data.jobs or jobs_data.workflow_jobs)) or {}
  if type(job_list) == "table" then
    for _, j in ipairs(job_list) do
      table.insert(jobs, map_job(j))
    end
  end
  return { run = map_run(run_data or {}), jobs = jobs, annotations = {} }, nil
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param run_id string|integer
---@param job_id string|integer
---@return ForgeCiJobDetail|nil, string|nil
function M.get_ci_job(_, remote, run_id, job_id)
  if not M.available(remote) then return nil, "Forgejo/Codeberg token missing or curl unavailable" end
  local run_data, err =
    api(remote, "GET", string.format("/repos/%s/%s/actions/runs/%s", remote.owner, remote.repo, tostring(run_id)))
  if err then return nil, err end
  local job_data, jerr =
    api(remote, "GET", string.format("/repos/%s/%s/actions/jobs/%s", remote.owner, remote.repo, tostring(job_id)))
  if jerr then return nil, jerr end
  return { run = map_run(run_data or {}), job = map_job(job_data or {}), annotations = {} }, nil
end

---@param _ string
---@param remote { host: string, owner: string, repo: string }
---@param _run_id string|integer
---@param job_id string|integer
---@return string[], string|nil
function M.get_ci_job_logs(_, remote, _run_id, job_id)
  if not M.available(remote) then return {}, "Forgejo/Codeberg token missing or curl unavailable" end
  local text, err =
    api_text(remote, string.format("/repos/%s/%s/actions/jobs/%s/logs", remote.owner, remote.repo, tostring(job_id)))
  if err then return {}, err end
  if not text or text == "" then return { "(empty log)" }, nil end
  return vim.split(text, "\n", { plain = true }), nil
end

return M
