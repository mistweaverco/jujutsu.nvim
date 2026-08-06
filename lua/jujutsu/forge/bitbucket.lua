local cache = require("jujutsu.forge.cache")
local credentials = require("jujutsu.forge.credentials")
local http = require("jujutsu.forge.http")

local M = {}

local API_BASE = "https://api.bitbucket.org/2.0"

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
      draft = false,
      labels = false,
    },
    issues = {
      list = true,
      search = true,
      create = true,
      update = true,
      close = true,
      labels = false,
    },
    comments = { list = true, create = true, update = true, delete = true },
    ci = { list = true, cancel = true, trigger = true, view = true, logs = true },
  }
end

---@param remote? { owner: string }
---@return string|nil, string|nil, string|nil
local function resolve(remote)
  if remote then
    local creds = credentials.resolve(remote)
    if creds and creds.user and creds.token then return creds.user, creds.token, nil end
  end
  return nil, nil, "Missing Bitbucket credentials for workspace (will prompt on review)"
end

---@param remote? { owner: string }
---@return boolean
function M.available(remote)
  if vim.fn.executable("curl") ~= 1 then return false end
  if remote then return credentials.has(remote) end
  return true
end

---@param path_or_url string
---@return string
local function normalize_url(path_or_url)
  local url = path_or_url
  if not url:match("^https?://") then
    if url:sub(1, 1) ~= "/" then url = "/" .. url end
    url = API_BASE .. url
  end
  return url
end

---@param remote { owner: string, repo: string }
---@param method string
---@param path_or_url string
---@param body? table|false nil = no body; table = JSON body; false unused
---@return table|nil, string|nil
local function api_request(remote, method, path_or_url, body)
  local user, token, auth_err = resolve(remote)
  if auth_err then return nil, auth_err end
  local url = normalize_url(path_or_url)
  if type(user) ~= "string" or user == "" or type(token) ~= "string" or token == "" then
    return nil, "Missing Bitbucket credentials"
  end
  local has_body = body ~= nil
  local headers = {
    Authorization = http.basic_auth(user, token),
    Accept = "application/json",
    ["Content-Type"] = has_body and "application/json" or nil,
  }
  local res = http.request(method, url, headers, has_body and http.encode_json(body) or nil)
  if res.err then return nil, res.err end
  return res.json or {}, nil
end

---@param remote { owner: string, repo: string }
---@param method string
---@param path_or_url string
---@param body? table|false nil = no body; table = JSON body; false unused
---@return table|nil, string|nil
local function api(remote, method, path_or_url, body)
  if not cache.is_http_read(method) then
    local result, err = api_request(remote, method, path_or_url, body)
    if result and not err then cache.clear() end
    return result, err
  end
  local url = normalize_url(path_or_url)
  local body_key = body ~= nil and http.encode_json(body) or ""
  local cache_key = cache.key("bitbucket", remote.owner, remote.repo, method, url, body_key)
  return cache.fetch(cache_key, function() return api_request(remote, method, path_or_url, body) end)
end

---Bitbucket step logs are raw octet-stream, not JSON.
---@param remote { owner: string, repo: string }
---@param method string
---@param path_or_url string
---@param accept? string
---@return string|nil, string|nil
local function api_text_request(remote, method, path_or_url, accept)
  local user, token, auth_err = resolve(remote)
  if auth_err then return nil, auth_err end
  local url = normalize_url(path_or_url)
  if type(user) ~= "string" or user == "" or type(token) ~= "string" or token == "" then
    return nil, "Missing Bitbucket credentials"
  end
  local headers = {
    Authorization = http.basic_auth(user, token),
    Accept = accept or "*/*",
  }
  local res = http.request(method, url, headers, nil, { follow_redirects = true })
  if res.err then return nil, res.err end
  return res.body or "", nil
end

---Bitbucket step logs are raw octet-stream, not JSON.
---@param remote { owner: string, repo: string }
---@param method string
---@param path_or_url string
---@param accept? string
---@return string|nil, string|nil
local function api_text(remote, method, path_or_url, accept)
  if not cache.is_http_read(method) then
    local result, err = api_text_request(remote, method, path_or_url, accept)
    if result and not err then cache.clear() end
    return result, err
  end
  local url = normalize_url(path_or_url)
  local cache_key = cache.key("bitbucket-text", remote.owner, remote.repo, method, url, accept or "*/*")
  return cache.fetch(cache_key, function() return api_text_request(remote, method, path_or_url, accept) end)
end

---@param id string|integer
---@return string
local function fmt_uuid(id)
  local s = tostring(id):gsub("[{}]", "")
  return "{" .. s .. "}"
end

---URL-encode pipeline UUID for Bitbucket path segments ({uuid} → %7Buuid%7D).
---@param id string|integer
---@return string
local function pipeline_path_id(id)
  local uuid = fmt_uuid(id)
  if vim.uri_encode then return vim.uri_encode(uuid) end
  return uuid:gsub("([^%w%-%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)
end

---@param target table|nil
---@return string|nil
local function target_ref_name(target)
  if not target or type(target) ~= "table" then return nil end
  if target.ref_name and target.ref_name ~= "" then return target.ref_name end
  if target.ref and target.ref ~= "" then return target.ref end
  if target.selector and target.selector.pattern then return target.selector.pattern end
  return nil
end

---@param owner string
---@param repo string
---@param build_number? integer|string
---@param pipeline_uuid? string
---@return string
local function pipeline_web_url(owner, repo, build_number, pipeline_uuid)
  if build_number then
    return string.format("https://bitbucket.org/%s/%s/pipelines/results/%s", owner, repo, tostring(build_number))
  end
  if pipeline_uuid and pipeline_uuid ~= "" then
    return string.format(
      "https://bitbucket.org/%s/%s/pipelines/results/%s",
      owner,
      repo,
      pipeline_path_id(pipeline_uuid)
    )
  end
  return ""
end

---@param owner string
---@param repo string
---@param build_number? integer|string
---@param step_uuid? string
---@param pipeline_uuid? string
---@return string
local function step_web_url(owner, repo, build_number, step_uuid, pipeline_uuid)
  local base = pipeline_web_url(owner, repo, build_number, pipeline_uuid)
  if base == "" or not step_uuid or step_uuid == "" then return base end
  return base .. "/steps/" .. pipeline_path_id(step_uuid)
end

---@param p table
---@param remote { owner: string, repo: string }
---@return ForgeCiRun
local function map_pipeline(p, remote)
  local state_name = (p.state and p.state.name) or ""
  local result_name = (p.state and p.state.result and p.state.result.name) or ""
  local can_cancel = state_name == "PENDING" or state_name == "IN_PROGRESS" or state_name == "QUEUED"
  local uuid = p.uuid and tostring(p.uuid):gsub("[{}]", "") or ""
  local build = p.build_number and tostring(p.build_number) or "?"
  local branch = target_ref_name(p.target)
  local title = branch or ("pipeline #" .. build)
  local url = (p.links and p.links.html and p.links.html.href) or ""
  if url == "" then url = pipeline_web_url(remote.owner, remote.repo, p.build_number, uuid) end
  return {
    id = uuid ~= "" and uuid or tostring(p.build_number or ""),
    name = string.format("pipeline #%s", build),
    title = title,
    workflow = "Pipeline",
    event = (p.trigger and p.trigger.name) or "push",
    status = state_name,
    conclusion = result_name ~= "" and result_name or state_name,
    url = url,
    can_cancel = can_cancel,
    branch = branch,
    head_sha = p.target and p.target.commit and p.target.commit.hash,
    created_at = p.created_on,
    updated_at = p.completed_on,
    started_at = p.created_on,
    elapsed = p.duration_in_seconds and (tostring(p.duration_in_seconds) .. "s") or "",
  }
end

---@param s table
---@param remote { owner: string, repo: string }
---@param pipeline? table
---@return ForgeCiJob
local function map_step(s, remote, pipeline)
  local step_uuid = s.uuid and tostring(s.uuid):gsub("[{}]", "") or ""
  local url = (s.links and s.links.html and s.links.html.href) or ""
  if url == "" then
    url = step_web_url(
      remote.owner,
      remote.repo,
      pipeline and pipeline.build_number,
      step_uuid,
      pipeline and pipeline.uuid and tostring(pipeline.uuid):gsub("[{}]", "") or nil
    )
  end
  local state_name = (s.state and s.state.name) or ""
  local result_name = (s.result and s.result.name) or ((s.state and s.state.result and s.state.result.name) or "")
  return {
    id = step_uuid ~= "" and step_uuid or tostring(s.name or "?"),
    name = s.name or ("step " .. tostring(s.uuid or "?")),
    status = state_name,
    conclusion = result_name ~= "" and result_name or state_name,
    url = url,
    elapsed = s.duration_in_seconds and (tostring(s.duration_in_seconds) .. "s") or "",
    steps = {},
  }
end

---@param remote { owner: string, repo: string }
---@param url string
---@return table[], string|nil
local function fetch_all(remote, url)
  local values = {}
  local next_url = url
  while next_url and next_url ~= "" do
    local result, err = api(remote, "GET", next_url)
    if err or not result then return values, err end
    for _, v in ipairs(result.values or {}) do
      table.insert(values, v)
    end
    next_url = type(result.next) == "string" and result.next or ""
  end
  return values, nil
end

---@param remote { owner: string, repo: string }
---@param run_id string|integer
---@return string|nil, string|nil
local function resolve_pipeline_id(remote, run_id)
  local id = tostring(run_id):gsub("[{}]", "")
  if id:match("^[%x%-]+$") and #id >= 32 then return id, nil end
  if not id:match("^%d+$") then return id, nil end
  local values, err = fetch_all(
    remote,
    string.format("/repositories/%s/%s/pipelines?pagelen=100&sort=-created_on", remote.owner, remote.repo)
  )
  if err then return nil, err end
  for _, p in ipairs(values) do
    if tostring(p.build_number) == id then
      local uuid = p.uuid and tostring(p.uuid):gsub("[{}]", "") or ""
      if uuid ~= "" then return uuid, nil end
    end
  end
  return nil, "pipeline build #" .. id .. " not found"
end

---@param remote { owner: string, repo: string }
---@param pipeline_id string
---@param step_id string
---@return string[], string|nil
local function fetch_step_log(remote, pipeline_id, step_id)
  local endpoint = string.format(
    "/repositories/%s/%s/pipelines/%s/steps/%s/log",
    remote.owner,
    remote.repo,
    pipeline_path_id(pipeline_id),
    pipeline_path_id(step_id)
  )
  local body, err = api_text(remote, "GET", endpoint)
  if err then
    if err:match("HTTP 404") then return { "(empty log)" }, nil end
    return {}, err
  end
  if not body or body == "" then return { "(empty log)" }, nil end
  if body:sub(-1) == "\n" then body = body:sub(1, -2) end
  if body == "" then return { "(empty log)" }, nil end
  return vim.split(body, "\n", { plain = true }), nil
end

---@param remote { owner: string, repo: string }
---@param url string
---@return table[], string|nil, boolean
local function fetch_page(remote, url)
  local result, err = api(remote, "GET", url)
  if err or not result then return {}, err, false end
  local values = result.values or {}
  local has_more = type(result.next) == "string" and result.next ~= ""
  return values, nil, has_more
end

---@param _ string
---@param remote { owner: string, repo: string }
-- luacheck: ignore 631
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[], string|nil
function M.list_prs(_, remote)
  if not M.available(remote) then return {}, "Bitbucket credentials missing or curl unavailable" end
  local endpoint = string.format("/repositories/%s/%s/pullrequests?state=OPEN&pagelen=50", remote.owner, remote.repo)
  local values, err = fetch_all(remote, endpoint)
  if err then return {}, err end
  local out = {}
  for _, pr in ipairs(values) do
    local html = ""
    if pr.links and pr.links.html and pr.links.html.href then html = pr.links.html.href end
    table.insert(out, {
      number = pr.id,
      title = pr.title or "",
      url = html,
      head_ref = (pr.source and pr.source.branch and pr.source.branch.name) or "",
      base_ref = (pr.destination and pr.destination.branch and pr.destination.branch.name) or "",
      head_sha = (pr.source and pr.source.commit and pr.source.commit.hash) or "",
      base_sha = (pr.destination and pr.destination.commit and pr.destination.commit.hash) or "",
      _raw = pr,
    })
  end
  return out, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return table|nil, string|nil
function M.get_pr(_, remote, number)
  if not M.available(remote) then return nil, "Bitbucket credentials missing or curl unavailable" end
  local pr, err = api(
    remote,
    "GET",
    string.format("/repositories/%s/%s/pullrequests/%s", remote.owner, remote.repo, tostring(number))
  )
  if err then return nil, err end
  if type(pr) ~= "table" then return nil, "invalid PR response" end
  local html = ""
  if pr.links and pr.links.html and pr.links.html.href then html = pr.links.html.href end
  return {
    number = pr.id,
    title = pr.title or "",
    url = html,
    head_ref = (pr.source and pr.source.branch and pr.source.branch.name) or "",
    base_ref = (pr.destination and pr.destination.branch and pr.destination.branch.name) or "",
    head_sha = (pr.source and pr.source.commit and pr.source.commit.hash) or "",
    base_sha = (pr.destination and pr.destination.commit and pr.destination.commit.hash) or "",
    body = (pr.description and (pr.description.raw or pr.description)) or "",
    _raw = pr,
  }
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { event?: string, body?: string, comments?: { path: string, body: string, line?: integer, side?: string, start_line?: integer }[] }
---@return boolean, string|nil, { posted_comments?: boolean }|nil
function M.submit_review(root, remote, number, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  if opts.event == "DRAFT" then return false, "Draft reviews are GitHub-only" end

  local pr, err = M.get_pr(root, remote, number)
  if err or not pr then return false, err or "PR not found" end
  local comments_url = pr._raw and pr._raw.links and pr._raw.links.comments and pr._raw.links.comments.href
  if not comments_url then
    comments_url = string.format(
      "%s/repositories/%s/%s/pullrequests/%s/comments",
      API_BASE,
      remote.owner,
      remote.repo,
      tostring(number)
    )
  end

  local posted_comments = false
  local function meta() return { posted_comments = posted_comments } end

  for _, c in ipairs(opts.comments or {}) do
    local payload = {
      content = { raw = c.body or "" },
    }
    if c.path and c.line then
      local inline = { path = c.path }
      if c.side == "LEFT" then
        inline.from = c.line
        if c.start_line and c.start_line ~= c.line then inline.start_from = c.start_line end
      else
        inline.to = c.line
        if c.start_line and c.start_line ~= c.line then inline.start_to = c.start_line end
      end
      payload.inline = inline
    end
    local _, cerr = api(remote, "POST", comments_url, payload)
    if cerr then return false, "Posting comment failed: " .. cerr, meta() end
    posted_comments = true
  end

  if opts.body and opts.body ~= "" then
    local _, cerr = api(remote, "POST", comments_url, { content = { raw = opts.body } })
    if cerr then return false, "Posting review body failed: " .. cerr, meta() end
    posted_comments = true
  end

  local event = opts.event or "COMMENT"
  local function event_err(action, api_err)
    local hint = ""
    local msg = tostring(api_err or "")
    if
      msg:match("HTTP 401")
      or msg:lower():find("privilege scopes", 1, true)
      or msg:find("write:pullrequest", 1, true)
    then
      hint =
        " Create an Atlassian API token that includes write:pullrequest:bitbucket (your token currently looks read-only for PRs), then update stored credentials."
    elseif msg:match("HTTP 403") then
      hint = " You may lack permission to " .. action .. " on this PR."
    end
    local already = posted_comments and " Comments were already posted to Bitbucket." or ""
    return string.format("%s failed: %s.%s%s", action, api_err or "unknown error", already, hint)
  end

  if event == "APPROVE" then
    -- Bitbucket approve/request-changes are body-less POSTs.
    local _, aerr = api(
      remote,
      "POST",
      string.format("/repositories/%s/%s/pullrequests/%s/approve", remote.owner, remote.repo, tostring(number))
    )
    if aerr then return false, event_err("Approve", aerr), meta() end
  elseif event == "REQUEST_CHANGES" then
    local _, rerr = api(
      remote,
      "POST",
      string.format("/repositories/%s/%s/pullrequests/%s/request-changes", remote.owner, remote.repo, tostring(number))
    )
    if rerr then return false, event_err("Request changes", rerr), meta() end
  end

  return true, nil, meta()
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return ForgeRemoteComment[]
function M.list_review_comments(root, remote, number)
  if not M.available(remote) then return {} end
  local pr, err = M.get_pr(root, remote, number)
  if err or not pr then return {} end
  local comments_url = pr._raw and pr._raw.links and pr._raw.links.comments and pr._raw.links.comments.href
  if not comments_url then
    comments_url = string.format(
      "%s/repositories/%s/%s/pullrequests/%s/comments?pagelen=100",
      API_BASE,
      remote.owner,
      remote.repo,
      tostring(number)
    )
  elseif not comments_url:find("pagelen=", 1, true) then
    local sep = comments_url:find("?", 1, true) and "&" or "?"
    comments_url = comments_url .. sep .. "pagelen=100"
  end

  local threads = require("jujutsu.review.threads")
  local values = select(1, fetch_all(remote, comments_url))
  local out = {}
  for _, c in ipairs(values or {}) do
    local author = "unknown"
    if c.user then author = c.user.display_name or c.user.nickname or c.user.uuid or author end
    local body = ""
    if type(c.content) == "table" then
      body = c.content.raw or c.content.markup or ""
    elseif type(c.content) == "string" then
      body = c.content
    end
    local parent_id = nil
    if type(c.parent) == "table" and c.parent.id then parent_id = threads.remote_id(c.parent.id) end

    local path, side, line, start_line
    local inline = c.inline
    if type(inline) == "table" and inline.path then
      path = inline.path
      local to = threads.as_line(inline.to)
      local from = threads.as_line(inline.from)
      if to then
        side, line = "RIGHT", to
      elseif from then
        side, line = "LEFT", from
      end
      start_line = threads.as_line(inline.start_to) or threads.as_line(inline.start_from)
    end

    -- Keep replies without inline so we can inherit location from the parent.
    if (path and line) or parent_id then
      table.insert(out, {
        id = threads.remote_id(c.id),
        path = path,
        side = side,
        line = line,
        start_line = start_line,
        body = body,
        author = author,
        outdated = false,
        url = c.links and c.links.html and c.links.html.href or nil,
        remote = true,
        kind = "line",
        parent_id = parent_id,
        provider = "bitbucket",
        created_at = c.created_on,
        updated_at = c.updated_on,
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

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@return ForgeTopic|nil, string|nil
function M.get_topic(_, remote, number, opts)
  if not M.available(remote) then return nil, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local kind = opts.kind or "pr"

  if kind == "issue" then
    local issue, err =
      api(remote, "GET", string.format("/repositories/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number)))
    if err or type(issue) ~= "table" then return nil, err or "failed to fetch issue" end
    local html = ""
    if issue.links and issue.links.html and issue.links.html.href then html = issue.links.html.href end
    local assignees = {}
    if issue.assignee and issue.assignee.display_name then table.insert(assignees, issue.assignee.display_name) end
    return {
      kind = "issue",
      number = issue.id or number,
      title = issue.title or "",
      body = (issue.content and (issue.content.raw or issue.content.markup)) or "",
      state = (issue.state and (issue.state.name or issue.state)) or "open",
      author = (issue.reporter and (issue.reporter.display_name or issue.reporter.nickname)) or "unknown",
      created_at = issue.created_on,
      updated_at = issue.updated_on,
      labels = {},
      assignees = assignees,
      url = html,
      repo = remote.owner .. "/" .. remote.repo,
    }
  end

  local pr, err = M.get_pr(_, remote, number)
  if err or not pr then return nil, err or "failed to fetch PR" end
  local raw = pr._raw or {}
  local state = "open"
  if raw.state == "MERGED" then
    state = "merged"
  elseif raw.state == "DECLINED" or raw.state == "SUPERSEDED" then
    state = "closed"
  elseif raw.state then
    state = string.lower(tostring(raw.state))
  end
  local author = "unknown"
  if raw.author then author = raw.author.display_name or raw.author.nickname or author end
  local reviewers = {}
  for _, p in ipairs(raw.participants or {}) do
    if p.user then table.insert(reviewers, p.user.display_name or p.user.nickname or "?") end
  end
  return {
    kind = "pr",
    number = pr.number,
    title = pr.title or "",
    body = pr.body or "",
    state = state,
    merged = state == "merged",
    author = author,
    created_at = raw.created_on,
    updated_at = raw.updated_on,
    labels = {},
    assignees = reviewers,
    url = pr.url or "",
    repo = remote.owner .. "/" .. remote.repo,
  }
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@return ForgeConversationComment[], string|nil
function M.list_comments(_, remote, number, opts)
  if not M.available(remote) then return {}, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local kind = opts.kind or "pr"
  local url
  if kind == "issue" then
    url = string.format(
      "%s/repositories/%s/%s/issues/%s/comments?pagelen=100",
      "https://api.bitbucket.org/2.0",
      remote.owner,
      remote.repo,
      tostring(number)
    )
  else
    url = string.format(
      "%s/repositories/%s/%s/pullrequests/%s/comments?pagelen=100",
      "https://api.bitbucket.org/2.0",
      remote.owner,
      remote.repo,
      tostring(number)
    )
  end
  local values, err = fetch_all(remote, url)
  if err then return {}, err end
  local out = {}
  for _, c in ipairs(values) do
    -- Skip pure inline review comments without general content for PR conversation
    local body = ""
    if type(c.content) == "table" then
      body = c.content.raw or c.content.markup or ""
    elseif type(c.content) == "string" then
      body = c.content
    end
    if body ~= "" and (kind == "issue" or not c.inline) then
      local author = "unknown"
      if c.user then author = c.user.display_name or c.user.nickname or author end
      table.insert(out, {
        id = tostring(c.id),
        author = author,
        created_at = c.created_on,
        updated_at = c.updated_on,
        body = body,
        url = c.links and c.links.html and c.links.html.href or nil,
        kind = "comment",
      })
    end
  end
  return out, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param body string
---@param opts? { kind?: "issue"|"pr" }
---@return boolean, string|nil
function M.post_comment(_, remote, number, body, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  opts = opts or {}
  local kind = opts.kind or "pr"
  local path
  if kind == "issue" then
    path = string.format("/repositories/%s/%s/issues/%s/comments", remote.owner, remote.repo, tostring(number))
  else
    path = string.format("/repositories/%s/%s/pullrequests/%s/comments", remote.owner, remote.repo, tostring(number))
  end
  local _, err = api(remote, "POST", path, { content = { raw = body } })
  if err then return false, err end
  return true
end

---Reply to a PR comment (`parent.id`).
---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { parent_id: string|integer, body: string }
---@return boolean, string|nil
function M.post_reply(_, remote, number, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local body = opts.body
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local threads = require("jujutsu.review.threads")
  local parent = tonumber(threads.raw_id(opts.parent_id))
  if not parent then return false, "Missing parent comment id" end
  local path =
    string.format("/repositories/%s/%s/pullrequests/%s/comments", remote.owner, remote.repo, tostring(number))
  local _, err = api(remote, "POST", path, {
    content = { raw = body },
    parent = { id = parent },
  })
  if err then return false, err end
  return true
end

---@param _root string
---@param remote { owner: string, repo: string }
---@param filter? ForgeSearchFilter
---@return table[], string|nil
function M.search_prs(_root, remote, filter)
  if not M.available(remote) then return {}, "Bitbucket credentials missing or curl unavailable" end
  filter = filter or {}
  local state = string.upper(filter.state or "OPEN")
  if state == "OPENED" then state = "OPEN" end
  if state == "CLOSED" then state = "DECLINED" end
  if state == "ALL" then state = nil end
  local endpoint = string.format(
    "/repositories/%s/%s/pullrequests?pagelen=%s",
    remote.owner,
    remote.repo,
    tostring(filter.limit or 50)
  )
  if state then endpoint = endpoint .. "&state=" .. state end
  if filter.query and filter.query ~= "" then endpoint = endpoint .. "&q=title~%22" .. filter.query .. "%22" end
  local values, err = fetch_all(remote, endpoint)
  if err then return {}, err end
  local out = {}
  for _, pr in ipairs(values) do
    local html = ""
    if pr.links and pr.links.html and pr.links.html.href then html = pr.links.html.href end
    table.insert(out, {
      number = pr.id,
      title = pr.title or "",
      url = html,
      head_ref = (pr.source and pr.source.branch and pr.source.branch.name) or "",
      base_ref = (pr.destination and pr.destination.branch and pr.destination.branch.name) or "",
      head_sha = (pr.source and pr.source.commit and pr.source.commit.hash) or "",
      base_sha = (pr.destination and pr.destination.commit and pr.destination.commit.hash) or "",
      state = pr.state or "OPEN",
      kind = "pr",
    })
  end
  return out, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param opts { title: string, body?: string, head?: string, base?: string }
---@return table|nil, string|nil
function M.create_pr(_, remote, opts)
  if not M.available(remote) then return nil, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  if not opts.title or opts.title == "" then return nil, "Title required" end
  if not opts.head or opts.head == "" then return nil, "head branch required" end
  local payload = {
    title = opts.title,
    description = opts.body or "",
    source = { branch = { name = opts.head } },
    destination = { branch = { name = opts.base or "main" } },
  }
  local pr, err =
    api(remote, "POST", string.format("/repositories/%s/%s/pullrequests", remote.owner, remote.repo), payload)
  if err or type(pr) ~= "table" then return nil, err or "failed to create PR" end
  local html = ""
  if pr.links and pr.links.html and pr.links.html.href then html = pr.links.html.href end
  return {
    number = pr.id,
    title = pr.title or opts.title,
    url = html,
    head_ref = opts.head,
    base_ref = opts.base or "main",
  },
    nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { title?: string, body?: string }
---@return boolean, string|nil
function M.update_pr(_, remote, number, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local payload = {}
  if opts.title then payload.title = opts.title end
  -- Bitbucket returns description as a rich-text object; updates take a plain string.
  if opts.body ~= nil then payload.description = opts.body end
  if next(payload) == nil then return true end
  local _, err = api(
    remote,
    "PUT",
    string.format("/repositories/%s/%s/pullrequests/%s", remote.owner, remote.repo, tostring(number)),
    payload
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return boolean, string|nil
function M.close_pr(_, remote, number)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  local _, err = api(
    remote,
    "POST",
    string.format("/repositories/%s/%s/pullrequests/%s/decline", remote.owner, remote.repo, tostring(number)),
    {}
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param _opts? { method?: string }
---@return boolean, string|nil
function M.merge_pr(_, remote, number, _opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  local _, err = api(
    remote,
    "POST",
    string.format("/repositories/%s/%s/pullrequests/%s/merge", remote.owner, remote.repo, tostring(number)),
    { close_source_branch = false, merge_strategy = "merge_commit" }
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param _ { owner: string, repo: string }
---@return ForgeLabel[], string|nil
function M.list_repo_labels(_, _) return {}, nil end

---@param _ string
---@param remote { owner: string, repo: string }
---@param filter? ForgeSearchFilter
---@return table[], string|nil
function M.search_issues(_, remote, filter)
  if not M.available(remote) then return {}, "Bitbucket credentials missing or curl unavailable" end
  filter = filter or {}
  local endpoint =
    string.format("/repositories/%s/%s/issues?pagelen=%s", remote.owner, remote.repo, tostring(filter.limit or 50))
  if filter.state == "open" then
    endpoint = endpoint .. "&status=new&status=open"
  elseif filter.state == "closed" then
    endpoint = endpoint .. "&status=closed&status=resolved"
  end
  if filter.query and filter.query ~= "" then endpoint = endpoint .. "&q=title~%22" .. filter.query .. "%22" end
  local values, err = fetch_all(remote, endpoint)
  if err then return {}, err end
  local out = {}
  for _, issue in ipairs(values) do
    local html = ""
    if issue.links and issue.links.html and issue.links.html.href then html = issue.links.html.href end
    table.insert(out, {
      number = issue.id,
      title = issue.title or "",
      url = html,
      state = (issue.state and (issue.state.name or issue.state)) or "open",
      labels = {},
      kind = "issue",
      author = (issue.reporter and (issue.reporter.display_name or issue.reporter.nickname)) or "",
    })
  end
  return out, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param opts { title: string, body?: string }
---@return table|nil, string|nil
function M.create_issue(_, remote, opts)
  if not M.available(remote) then return nil, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  if not opts.title or opts.title == "" then return nil, "Title required" end
  local payload = {
    title = opts.title,
    content = { raw = opts.body or "", markup = "markdown" },
  }
  local issue, err =
    api(remote, "POST", string.format("/repositories/%s/%s/issues", remote.owner, remote.repo), payload)
  if err or type(issue) ~= "table" then return nil, err or "failed to create issue" end
  local html = ""
  if issue.links and issue.links.html and issue.links.html.href then html = issue.links.html.href end
  return {
    number = issue.id,
    title = issue.title or opts.title,
    url = html,
    kind = "issue",
  }, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { title?: string, body?: string, state?: string }
---@return boolean, string|nil
function M.update_issue(_, remote, number, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local payload = {}
  if opts.title then payload.title = opts.title end
  if opts.body ~= nil then payload.content = { raw = opts.body, markup = "markdown" } end
  if opts.state == "closed" then
    payload.state = { name = "closed" }
  elseif opts.state == "open" then
    payload.state = { name = "open" }
  end
  local _, err = api(
    remote,
    "PUT",
    string.format("/repositories/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number)),
    payload
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return boolean, string|nil
function M.close_issue(_, remote, number) return M.update_issue(_, remote, number, { state = "closed" }) end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param comment_id string|integer
---@param body string
---@param opts? { kind?: "issue"|"pr" }
---@return boolean, string|nil
function M.update_comment(_, remote, number, comment_id, body, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  opts = opts or {}
  local path
  if opts.kind == "issue" then
    path = string.format(
      "/repositories/%s/%s/issues/%s/comments/%s",
      remote.owner,
      remote.repo,
      tostring(number),
      tostring(comment_id)
    )
  else
    path = string.format(
      "/repositories/%s/%s/pullrequests/%s/comments/%s",
      remote.owner,
      remote.repo,
      tostring(number),
      tostring(comment_id)
    )
  end
  local _, err = api(remote, "PUT", path, { content = { raw = body } })
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param comment_id string|integer
---@param opts? { kind?: "issue"|"pr" }
---@return boolean, string|nil
function M.delete_comment(_, remote, number, comment_id, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local path
  if opts.kind == "issue" then
    path = string.format(
      "/repositories/%s/%s/issues/%s/comments/%s",
      remote.owner,
      remote.repo,
      tostring(number),
      tostring(comment_id)
    )
  else
    path = string.format(
      "/repositories/%s/%s/pullrequests/%s/comments/%s",
      remote.owner,
      remote.repo,
      tostring(number),
      tostring(comment_id)
    )
  end
  local _, err = api(remote, "DELETE", path)
  if err then return false, err end
  return true
end

---@param err string|nil
---@return string|nil
local function pipeline_err(err)
  if not err or type(err) ~= "string" then return err end
  if http.is_scope_error(err) then
    return err
      .. "\n\nYour Bitbucket token is valid but missing pipeline scopes."
      .. "\nCreate a new API token with read:pipeline:bitbucket (Pipelines → Read)."
      .. "\nFor cancel/trigger, also add write:pipeline:bitbucket."
      .. "\nBitbucket API tokens do not inherit scopes - Write does not grant Read."
  end
  return err
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param opts? { branch?: string, limit?: integer }
---@return ForgeCiRun[], string|nil, ForgeCiListMeta|nil
function M.list_ci_runs(_, remote, opts)
  if not M.available(remote) then return {}, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local limit = opts.limit or 20
  local endpoint = string.format(
    "/repositories/%s/%s/pipelines?pagelen=%s&sort=-created_on",
    remote.owner,
    remote.repo,
    tostring(limit)
  )
  local values, err, has_more = fetch_page(remote, endpoint)
  if err then return {}, pipeline_err(err) end
  local out = {}
  for _, p in ipairs(values) do
    table.insert(out, map_pipeline(p, remote))
  end
  return out, nil, { has_more = has_more }
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param run_id string|integer
---@return boolean, string|nil
function M.cancel_ci_run(_, remote, run_id)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  local pid, perr = resolve_pipeline_id(remote, run_id)
  if perr then return false, perr end
  local _, err = api(
    remote,
    "POST",
    string.format("/repositories/%s/%s/pipelines/%s/stopPipeline", remote.owner, remote.repo, pipeline_path_id(pid)),
    {}
  )
  if err then return false, err end
  return true
end

---@param _ string
---@param _ { owner: string, repo: string }
---@return ForgeWorkflow[], string|nil
function M.list_triggerable_workflows(_, _)
  return {
    {
      id = "pipeline",
      name = "Run pipeline",
      can_dispatch = true,
    },
  }, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param opts { workflow_id?: string|integer, ref?: string }
---@return boolean, string|nil
function M.trigger_ci(_, remote, opts)
  if not M.available(remote) then return false, "Bitbucket credentials missing or curl unavailable" end
  opts = opts or {}
  local ref = opts.ref or "main"
  local payload = {
    target = {
      ref_type = "branch",
      type = "pipeline_ref_target",
      ref_name = ref,
    },
  }
  local _, err =
    api(remote, "POST", string.format("/repositories/%s/%s/pipelines/", remote.owner, remote.repo), payload)
  if err then return false, err end
  return true
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param run_id string|integer
---@return ForgeCiRunDetail|nil, string|nil
function M.get_ci_run(_, remote, run_id)
  if not M.available(remote) then return nil, "Bitbucket credentials missing or curl unavailable" end
  local pid, perr = resolve_pipeline_id(remote, run_id)
  if perr then return nil, pipeline_err(perr) end
  local path_id = pipeline_path_id(pid)
  local pipeline, err =
    api(remote, "GET", string.format("/repositories/%s/%s/pipelines/%s", remote.owner, remote.repo, path_id))
  if err then return nil, pipeline_err(err) end
  local steps_data, serr =
    fetch_all(remote, string.format("/repositories/%s/%s/pipelines/%s/steps", remote.owner, remote.repo, path_id))
  if serr then return nil, pipeline_err(serr) end
  local jobs = {}
  for _, s in ipairs(steps_data) do
    table.insert(jobs, map_step(s, remote, pipeline))
  end
  return { run = map_pipeline(pipeline or {}, remote), jobs = jobs, annotations = {} }, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param run_id string|integer
---@param job_id string|integer
---@return ForgeCiJobDetail|nil, string|nil
function M.get_ci_job(_, remote, run_id, job_id)
  if not M.available(remote) then return nil, "Bitbucket credentials missing or curl unavailable" end
  local pid, perr = resolve_pipeline_id(remote, run_id)
  if perr then return nil, pipeline_err(perr) end
  local path_id = pipeline_path_id(pid)
  local pipeline, err =
    api(remote, "GET", string.format("/repositories/%s/%s/pipelines/%s", remote.owner, remote.repo, path_id))
  if err then return nil, pipeline_err(err) end
  local steps, serr =
    fetch_all(remote, string.format("/repositories/%s/%s/pipelines/%s/steps", remote.owner, remote.repo, path_id))
  if serr then return nil, pipeline_err(serr) end
  local job = nil
  local needle = tostring(job_id):gsub("[{}]", "")
  for _, s in ipairs(steps) do
    local sid = tostring(s.uuid or ""):gsub("[{}]", "")
    if sid == needle or tostring(s.name or "") == tostring(job_id) then
      job = map_step(s, remote, pipeline)
      break
    end
  end
  if not job then return nil, "step not found" end
  return { run = map_pipeline(pipeline or {}, remote), job = job, annotations = {} }, nil
end

---@param _ string
---@param remote { owner: string, repo: string }
---@param run_id string|integer
---@param job_id string|integer
---@return string[], string|nil
function M.get_ci_job_logs(_, remote, run_id, job_id)
  if not M.available(remote) then return {}, "Bitbucket credentials missing or curl unavailable" end
  local lines, err = fetch_step_log(remote, tostring(run_id), tostring(job_id))
  if err then return {}, pipeline_err(err) end
  return lines, nil
end

return M
