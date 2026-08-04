local labels_mod = require("jujutsu.forge.labels")

local M = {}

---@return boolean
function M.available() return vim.fn.executable("gh") == 1 end

---@param s string
---@return string
local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

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
    },
    issues = {
      list = true,
      search = true,
      create = true,
      update = true,
      close = true,
      labels = true,
    },
    comments = { list = true, create = true, update = true, delete = true },
    ci = { list = true, cancel = true, trigger = true },
  }
end

---@param root string
---@param args string[]
---@return { code: integer, stdout: string, stderr: string }
local function run(root, args)
  local obj = vim.system(vim.list_extend({ "gh" }, args), { cwd = root, text = true }):wait()
  return { code = obj.code, stdout = obj.stdout or "", stderr = obj.stderr or "" }
end

---@param root string
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[]
function M.list_prs(root)
  if not M.available() then return {} end
  local res = run(root, {
    "pr",
    "list",
    "--json",
    "number,title,url,headRefName,baseRefName,headRefOid,baseRefOid",
    "--limit",
    "50",
  })
  if res.code ~= 0 then return {} end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for _, pr in ipairs(data) do
    table.insert(out, {
      number = pr.number,
      title = pr.title or "",
      url = pr.url or "",
      head_ref = pr.headRefName or "",
      base_ref = pr.baseRefName or "",
      head_sha = pr.headRefOid or "",
      base_sha = pr.baseRefOid or "",
    })
  end
  return out
end

---@param root string
---@param number integer|string
---@return table|nil, string|nil
function M.get_pr(root, number)
  if not M.available() then return nil, "gh is not on PATH" end
  local res = run(root, {
    "pr",
    "view",
    tostring(number),
    "--json",
    "number,title,url,headRefName,baseRefName,headRefOid,baseRefOid,body",
  })
  if res.code ~= 0 then return nil, res.stderr ~= "" and res.stderr or "failed to fetch PR" end
  local ok, pr = pcall(vim.json.decode, res.stdout)
  if not ok or type(pr) ~= "table" then return nil, "invalid PR JSON" end
  return {
    number = pr.number,
    title = pr.title or "",
    url = pr.url or "",
    head_ref = pr.headRefName or "",
    base_ref = pr.baseRefName or "",
    head_sha = pr.headRefOid or "",
    base_sha = pr.baseRefOid or "",
    body = pr.body or "",
  }
end

---@class GitHubReviewComment
---@field path string
---@field body string
---@field line? integer
---@field side? string
---@field start_line? integer
---@field start_side? string

---@param stdout string
---@param stderr string
---@return string
local function format_api_error(stdout, stderr)
  local raw = (stdout and stdout ~= "" and stdout) or (stderr or "submit failed")
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" then
    local parts = {}
    if data.message and data.message ~= "" then table.insert(parts, data.message) end
    if type(data.errors) == "table" then
      for _, e in ipairs(data.errors) do
        if type(e) == "table" and e.message then
          table.insert(parts, e.message)
        elseif type(e) == "string" then
          table.insert(parts, e)
        end
      end
    end
    if #parts > 0 then return table.concat(parts, ": ") end
  end
  -- Prefer JSON body over `gh` generic "Unprocessable Entity (HTTP 422)" on `stderr`.
  if stdout and stdout ~= "" and not stdout:match("^gh:") then return stdout end
  return raw
end

---@param root string
---@param number integer|string
---@return string|nil
local function fresh_head_sha(root, number)
  local res = run(root, { "pr", "view", tostring(number), "--json", "headRefOid" })
  if res.code ~= 0 then return nil end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if ok and type(data) == "table" and data.headRefOid and data.headRefOid ~= "" then return data.headRefOid end
  return nil
end

---@param comments GitHubReviewComment[]
---@return string
local function comments_as_body(comments)
  local parts = {}
  for i, c in ipairs(comments) do
    local anchor = c.path or "?"
    if c.start_line and c.line and c.start_line < c.line then
      anchor = string.format("%s:%d-%d", c.path, c.start_line, c.line)
    elseif c.line then
      anchor = string.format("%s:%d", c.path, c.line)
    end
    table.insert(parts, string.format("%d. %s - %s", i, anchor, c.body or ""))
  end
  return table.concat(parts, "\n")
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param payload table
---@return boolean, string|nil, string|nil stdout
local function post_review(root, remote, number, payload)
  local endpoint = string.format("repos/%s/%s/pulls/%s/reviews", remote.owner, remote.repo, tostring(number))
  local obj = vim
    .system({ "gh", "api", "-X", "POST", endpoint, "--input", "-" }, {
      cwd = root,
      text = true,
      stdin = vim.json.encode(payload),
    })
    :wait()
  if obj.code ~= 0 then return false, format_api_error(obj.stdout or "", obj.stderr or ""), obj.stdout end
  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { event?: string, body?: string, commit_id?: string, comments?: GitHubReviewComment[] }
---@return boolean, string|nil
function M.submit_review(root, remote, number, opts)
  if not M.available() then return false, "gh is not on PATH" end
  opts = opts or {}

  local comments = {}
  for _, c in ipairs(opts.comments or {}) do
    local entry = {
      path = c.path,
      body = c.body,
    }
    if c.line then entry.line = c.line end
    if c.side then entry.side = c.side end
    if c.start_line and c.line and c.start_line < c.line then
      entry.start_line = c.start_line
      entry.start_side = c.start_side or c.side or "RIGHT"
    end
    table.insert(comments, entry)
  end

  local commit_id = fresh_head_sha(root, number) or opts.commit_id
  local function build_payload(inline)
    local payload = {}
    local body = opts.body or ""
    if commit_id and commit_id ~= "" then payload.commit_id = commit_id end
    if opts.event and opts.event ~= "" and opts.event ~= "DRAFT" then payload.event = opts.event end
    if inline and #inline > 0 then
      payload.comments = inline
    elseif body == "" and #comments > 0 then
      -- No inline comments: put them in the review summary.
      body = comments_as_body(comments)
    end
    payload.body = body
    return payload
  end

  local ok, err = post_review(root, remote, number, build_payload(comments))
  if ok then return true end

  -- Full-file DiffView lines often sit outside GitHub's PR hunks → 422.
  -- Also covers cases where gh only reports a generic "Unprocessable Entity".
  -- Retry once with comments folded into the review body (no inline anchors).
  if #comments > 0 then
    local body = opts.body or ""
    local folded = comments_as_body(comments)
    if body ~= "" then
      body = body .. "\n\n" .. folded
    else
      body = folded
    end
    local payload = { body = body }
    if commit_id and commit_id ~= "" then payload.commit_id = commit_id end
    if opts.event and opts.event ~= "" and opts.event ~= "DRAFT" then payload.event = opts.event end
    local ok2, err2 = post_review(root, remote, number, payload)
    if ok2 then return true end
    -- Prefer the more specific first error when the retry fails for the same reason.
    return false, err or err2
  end

  return false, err
end

---@class ForgeRemoteComment
---@field id string
---@field path string
---@field side "LEFT"|"RIGHT"
---@field line integer
---@field start_line? integer
---@field body string
---@field author string
---@field outdated? boolean
---@field url? string
---@field remote true
---@field parent_id? string
---@field discussion_id? string
---@field provider? string
---@field created_at? string
---@field updated_at? string
---@field supports_reply? boolean

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return ForgeRemoteComment[]
function M.list_review_comments(root, remote, number)
  if not M.available() then return {} end
  local threads = require("jujutsu.review.threads")
  local endpoint = string.format("repos/%s/%s/pulls/%s/comments", remote.owner, remote.repo, tostring(number))
  -- Request a high per_page
  -- paginate merges pages. Use Accept for the reviews API.
  local res = run(root, {
    "api",
    "--paginate",
    "-H",
    "Accept: application/vnd.github+json",
    endpoint .. "?per_page=100",
  })
  if res.code ~= 0 then return {} end
  local raw = vim.trim(res.stdout or "")
  if raw == "" then return {} end

  local data
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" then
    data = decoded
  else
    -- `gh` may emit one JSON array per page; merge them.
    local merged = {}
    local glued = raw:gsub("%]%s*%[", ",")
    if not glued:match("^%[") then glued = "[" .. glued .. "]" end
    local ook, arr = pcall(vim.json.decode, glued)
    if ook and type(arr) == "table" then merged = arr end
    data = merged
  end
  if type(data) ~= "table" then return {} end
  -- Prefer array; if object with unexpected shape, bail.
  if data[1] == nil and next(data) ~= nil and data.id then data = { data } end

  local out = {}
  for _, c in ipairs(data) do
    -- JSON null → vim.NIL (truthy); fall through to original_line for outdated comments.
    local line = threads.as_line(c.line) or threads.as_line(c.original_line)
    local start_line = threads.as_line(c.start_line) or threads.as_line(c.original_start_line)
    local path = c.path
    local parent_id = nil
    if c.in_reply_to_id then parent_id = threads.remote_id(c.in_reply_to_id) end
    if path and line then
      local side = c.side or "RIGHT"
      if side ~= "LEFT" and side ~= "RIGHT" then side = "RIGHT" end
      table.insert(out, {
        id = threads.remote_id(c.id),
        path = path,
        side = side,
        line = line,
        start_line = start_line,
        body = c.body or "",
        author = (c.user and (c.user.login or c.user.name)) or "unknown",
        outdated = threads.as_line(c.line) == nil and threads.as_line(c.original_line) ~= nil,
        url = c.html_url,
        remote = true,
        kind = "line",
        parent_id = parent_id,
        provider = "github",
        created_at = c.created_at,
        updated_at = c.updated_at,
        supports_reply = true,
      })
    elseif parent_id then
      -- Reply missing line: keep for inherit, then drop if still unresolved.
      table.insert(out, {
        id = threads.remote_id(c.id),
        path = path,
        side = c.side or "RIGHT",
        line = line,
        body = c.body or "",
        author = (c.user and (c.user.login or c.user.name)) or "unknown",
        outdated = true,
        url = c.html_url,
        remote = true,
        kind = "line",
        parent_id = parent_id,
        provider = "github",
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

---@param root string
---@param _ { owner: string, repo: string }
---@param path string
---@param method? string
---@param body? table
---@return table|nil, string|nil
local function api_json(root, _, path, method, body)
  local args = { "api", "-H", "Accept: application/vnd.github+json" }
  if method and method ~= "GET" then
    table.insert(args, "-X")
    table.insert(args, method)
  end
  if method == "GET" or not method then table.insert(args, "--paginate") end
  table.insert(args, path)
  local obj
  if body then
    obj = vim
      .system(vim.list_extend({ "gh" }, vim.list_extend(args, { "--input", "-" })), {
        cwd = root,
        text = true,
        stdin = require("jujutsu.forge.http").encode_json(body),
      })
      :wait()
  else
    obj = vim.system(vim.list_extend({ "gh" }, args), { cwd = root, text = true }):wait()
  end
  if obj.code ~= 0 then return nil, format_api_error(obj.stdout or "", obj.stderr or "") end
  local raw = vim.trim(obj.stdout or "")
  if raw == "" then return {}, nil end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" then return decoded, nil end
  -- paginated arrays
  local glued = raw:gsub("%]%s*%[", ",")
  if not glued:match("^%[") then glued = "[" .. glued .. "]" end
  local ook, arr = pcall(vim.json.decode, glued)
  if ook and type(arr) == "table" then return arr, nil end
  return nil, "invalid JSON from gh api"
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
    if type(u) == "table" then table.insert(out, u.login or u.name or tostring(u.id or "?")) end
  end
  return out
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@return ForgeTopic|nil, string|nil
function M.get_topic(root, remote, number, opts)
  if not M.available() then return nil, "gh is not on PATH" end
  opts = opts or {}
  local kind = opts.kind or "issue"
  local issue_path = string.format("repos/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number))
  local issue, err = api_json(root, remote, issue_path)
  if err or type(issue) ~= "table" then return nil, err or "failed to fetch issue" end

  local state = issue.state or "open"
  local draft, merged = false, false
  local is_pr = (issue.pull_request ~= nil and issue.pull_request ~= vim.NIL) or kind == "pr"
  if is_pr then
    kind = "pr"
    local pr_path = string.format("repos/%s/%s/pulls/%s", remote.owner, remote.repo, tostring(number))
    local pr = select(1, api_json(root, remote, pr_path))
    if type(pr) == "table" then
      draft = pr.draft == true
      -- JSON null decodes as vim.NIL (truthy); only a real string timestamp means merged.
      merged = pr.merged == true or (type(pr.merged_at) == "string" and pr.merged_at ~= "")
      if merged then
        state = "merged"
      elseif draft and (pr.state == "open" or not pr.state) then
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
    number = issue.number or tonumber(number) or number,
    title = issue.title or "",
    body = issue.body or "",
    state = state,
    draft = draft,
    merged = merged,
    author = (issue.user and (issue.user.login or issue.user.name)) or "unknown",
    created_at = issue.created_at,
    updated_at = issue.updated_at,
    labels = map_labels(issue.labels),
    assignees = map_users(issue.assignees),
    url = issue.html_url or "",
    repo = remote.owner .. "/" .. remote.repo,
  }
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@return ForgeConversationComment[], string|nil
function M.list_comments(root, remote, number, opts)
  if not M.available() then return {}, "gh is not on PATH" end
  opts = opts or {}
  local path = string.format("repos/%s/%s/issues/%s/comments?per_page=100", remote.owner, remote.repo, tostring(number))
  local data, err = api_json(root, remote, path)
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  if data[1] == nil and data.id then data = { data } end

  local out = {}
  for _, c in ipairs(data) do
    table.insert(out, {
      id = tostring(c.id),
      author = (c.user and (c.user.login or c.user.name)) or "unknown",
      author_association = c.author_association,
      created_at = c.created_at,
      updated_at = c.updated_at,
      body = c.body or "",
      url = c.html_url,
      kind = "comment",
    })
  end

  if (opts.kind or "issue") == "pr" then
    local reviews_path =
      string.format("repos/%s/%s/pulls/%s/reviews?per_page=100", remote.owner, remote.repo, tostring(number))
    local reviews = select(1, api_json(root, remote, reviews_path))
    if type(reviews) == "table" then
      for _, r in ipairs(reviews) do
        local body = r.body or ""
        if body ~= "" then
          table.insert(out, {
            id = "review-" .. tostring(r.id),
            author = (r.user and (r.user.login or r.user.name)) or "unknown",
            author_association = r.author_association,
            created_at = r.submitted_at or r.created_at,
            body = body,
            url = r.html_url,
            kind = "review",
          })
        end
      end
    end
  end

  table.sort(out, function(a, b) return tostring(a.created_at or "") < tostring(b.created_at or "") end)
  return out, nil
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param body string
---@param _opts? { kind?: "issue"|"pr" }
---@return boolean, string|nil
function M.post_comment(root, remote, number, body, _opts)
  if not M.available() then return false, "gh is not on PATH" end
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local path = string.format("repos/%s/%s/issues/%s/comments", remote.owner, remote.repo, tostring(number))
  local _, err = api_json(root, remote, path, "POST", { body = body })
  if err then return false, err end
  return true
end

---Reply to an inline PR review comment (`in_reply_to`).
---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { parent_id: string|integer, body: string }
---@return boolean, string|nil
function M.post_reply(root, remote, number, opts)
  if not M.available() then return false, "gh is not on PATH" end
  opts = opts or {}
  local body = opts.body
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local threads = require("jujutsu.review.threads")
  local parent = tonumber(threads.raw_id(opts.parent_id))
  if not parent then return false, "Missing parent comment id" end
  local path = string.format("repos/%s/%s/pulls/%s/comments", remote.owner, remote.repo, tostring(number))
  local _, err = api_json(root, remote, path, "POST", { body = body, in_reply_to = parent })
  if err then return false, err end
  return true
end

---@param filter ForgeSearchFilter
---@return string
local function build_pr_search(filter)
  local parts = {}
  local state = filter.state or "open"
  if state == "open" or state == "closed" or state == "merged" then
    table.insert(parts, "is:" .. state)
  elseif state ~= "all" then
    table.insert(parts, "is:open")
  end
  table.insert(parts, "is:pr")
  if filter.assignee == "@me" then
    table.insert(parts, "assignee:@me")
  elseif filter.assignee and filter.assignee ~= "" then
    table.insert(parts, "assignee:" .. filter.assignee)
  end
  if filter.author == "@me" then
    table.insert(parts, "author:@me")
  elseif filter.author and filter.author ~= "" then
    table.insert(parts, "author:" .. filter.author)
  end
  if filter.draft == true then
    table.insert(parts, "is:draft")
  elseif filter.draft == false then
    table.insert(parts, "-is:draft")
  end
  if filter.label and filter.label ~= "" then table.insert(parts, "label:" .. filter.label) end
  if filter.query and filter.query ~= "" then table.insert(parts, filter.query) end
  return table.concat(parts, " ")
end

---@param root string
---@param _ { owner: string, repo: string }
---@param filter? ForgeSearchFilter
---@return table[], string|nil
function M.search_prs(root, _, filter)
  if not M.available() then return {}, "gh is not on PATH" end
  filter = filter or {}
  local limit = tostring(filter.limit or 50)
  local search = build_pr_search(filter)
  local res = run(root, {
    "pr",
    "list",
    "--search",
    search,
    "--limit",
    limit,
    "--json",
    "number,title,url,headRefName,baseRefName,headRefOid,baseRefOid,isDraft,state",
  })
  if res.code ~= 0 then return {}, res.stderr ~= "" and res.stderr or "failed to search PRs" end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if not ok or type(data) ~= "table" then return {}, "invalid PR search JSON" end
  local out = {}
  for _, pr in ipairs(data) do
    table.insert(out, {
      number = pr.number,
      title = pr.title or "",
      url = pr.url or "",
      head_ref = pr.headRefName or "",
      base_ref = pr.baseRefName or "",
      head_sha = pr.headRefOid or "",
      base_sha = pr.baseRefOid or "",
      draft = pr.isDraft == true,
      state = pr.state or "open",
      kind = "pr",
    })
  end
  return out, nil
end

---@param root string
---@param _ { owner: string, repo: string }
---@param opts { title: string, body?: string, head?: string, base?: string, draft?: boolean, labels?: string[] }
---@return table|nil, string|nil
function M.create_pr(root, _, opts)
  if not M.available() then return nil, "gh is not on PATH" end
  opts = opts or {}
  if not opts.title or opts.title == "" then return nil, "Title required" end
  local args = { "pr", "create", "--title", opts.title, "--body", opts.body or "" }
  if opts.head and opts.head ~= "" then
    table.insert(args, "--head")
    table.insert(args, opts.head)
  end
  if opts.base and opts.base ~= "" then
    table.insert(args, "--base")
    table.insert(args, opts.base)
  end
  if opts.draft then table.insert(args, "--draft") end
  for _, label in ipairs(opts.labels or {}) do
    table.insert(args, "--label")
    table.insert(args, label)
  end
  local res = run(root, args)
  if res.code ~= 0 then return nil, res.stderr ~= "" and res.stderr or "failed to create PR" end
  local url = vim.trim(res.stdout or "")
  local number = url:match("/pull/(%d+)")
  if number then
    local pr = select(1, M.get_pr(root, number))
    if pr then return pr, nil end
    return { number = tonumber(number), title = opts.title, url = url }, nil
  end
  return { title = opts.title, url = url }, nil
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { title?: string, body?: string, base?: string, draft?: boolean, labels?: string[] }
---@return boolean, string|nil
function M.update_pr(root, remote, number, opts)
  if not M.available() then return false, "gh is not on PATH" end
  opts = opts or {}
  local path = string.format("repos/%s/%s/pulls/%s", remote.owner, remote.repo, tostring(number))
  local payload = {}
  if opts.title then payload.title = opts.title end
  if opts.body ~= nil then payload.body = opts.body end
  if opts.base then payload.base = opts.base end
  if opts.draft ~= nil then payload.draft = opts.draft end
  if next(payload) then
    local _, err = api_json(root, remote, path, "PATCH", payload)
    if err then return false, err end
  end
  if opts.labels then
    local issue_path = string.format("repos/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number))
    local _, err = api_json(root, remote, issue_path, "PATCH", { labels = opts.labels })
    if err then return false, err end
  end
  return true
end

---@param root string
---@param _ { owner: string, repo: string }
---@param number integer|string
---@return boolean, string|nil
function M.close_pr(root, _, number)
  if not M.available() then return false, "gh is not on PATH" end
  local res = run(root, { "pr", "close", tostring(number) })
  if res.code ~= 0 then return false, res.stderr ~= "" and res.stderr or "failed to close PR" end
  return true
end

---@param root string
---@param _ { owner: string, repo: string }
---@param number integer|string
---@param opts? { method?: string }
---@return boolean, string|nil
function M.merge_pr(root, _, number, opts)
  if not M.available() then return false, "gh is not on PATH" end
  opts = opts or {}
  local args = { "pr", "merge", tostring(number) }
  local method = opts.method or "merge"
  if method == "squash" then
    table.insert(args, "--squash")
  elseif method == "rebase" then
    table.insert(args, "--rebase")
  else
    table.insert(args, "--merge")
  end
  local res = run(root, args)
  if res.code ~= 0 then return false, res.stderr ~= "" and res.stderr or "failed to merge PR" end
  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@return ForgeLabel[], string|nil
function M.list_repo_labels(root, remote)
  if not M.available() then return {}, "gh is not on PATH" end
  local path = string.format("repos/%s/%s/labels?per_page=100", remote.owner, remote.repo)
  local data, err = api_json(root, remote, path)
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  return map_labels(data), nil
end

---@param filter ForgeSearchFilter
---@return string
local function build_issue_search(filter)
  local parts = { "is:issue" }
  local state = filter.state or "open"
  if state == "open" or state == "closed" then
    table.insert(parts, "is:" .. state)
  elseif state ~= "all" then
    table.insert(parts, "is:open")
  end
  if filter.assignee == "@me" then
    table.insert(parts, "assignee:@me")
  elseif filter.assignee and filter.assignee ~= "" then
    table.insert(parts, "assignee:" .. filter.assignee)
  end
  if filter.author == "@me" then
    table.insert(parts, "author:@me")
  elseif filter.author and filter.author ~= "" then
    table.insert(parts, "author:" .. filter.author)
  end
  if filter.label and filter.label ~= "" then table.insert(parts, "label:" .. filter.label) end
  if filter.query and filter.query ~= "" then table.insert(parts, filter.query) end
  return table.concat(parts, " ")
end

---@param root string
---@param remote { owner: string, repo: string }
---@param filter? ForgeSearchFilter
---@return table[], string|nil
function M.search_issues(root, remote, filter)
  if not M.available() then return {}, "gh is not on PATH" end
  filter = filter or {}
  local q = string.format("repo:%s/%s %s", remote.owner, remote.repo, build_issue_search(filter))
  local path = string.format("search/issues?q=%s&per_page=%s", urlencode(q), tostring(filter.limit or 50))
  local data, err = api_json(root, remote, path)
  if err then return {}, err end
  local items = (type(data) == "table" and data.items) or {}
  local out = {}
  for _, issue in ipairs(items) do
    table.insert(out, {
      number = issue.number,
      title = issue.title or "",
      url = issue.html_url or "",
      state = issue.state or "open",
      labels = map_labels(issue.labels),
      kind = "issue",
      author = (issue.user and issue.user.login) or "",
    })
  end
  return out, nil
end

---@param root string
---@param remote { owner: string, repo: string }
---@param opts { title: string, body?: string, labels?: string[], assignees?: string[] }
---@return table|nil, string|nil
function M.create_issue(root, remote, opts)
  if not M.available() then return nil, "gh is not on PATH" end
  opts = opts or {}
  if not opts.title or opts.title == "" then return nil, "Title required" end
  local path = string.format("repos/%s/%s/issues", remote.owner, remote.repo)
  local payload = { title = opts.title, body = opts.body or "" }
  if opts.labels then payload.labels = opts.labels end
  if opts.assignees then payload.assignees = opts.assignees end
  local issue, err = api_json(root, remote, path, "POST", payload)
  if err or type(issue) ~= "table" then return nil, err or "failed to create issue" end
  return {
    number = issue.number,
    title = issue.title or opts.title,
    url = issue.html_url or "",
    kind = "issue",
  },
    nil
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { title?: string, body?: string, labels?: string[], state?: string }
---@return boolean, string|nil
function M.update_issue(root, remote, number, opts)
  if not M.available() then return false, "gh is not on PATH" end
  opts = opts or {}
  local path = string.format("repos/%s/%s/issues/%s", remote.owner, remote.repo, tostring(number))
  local payload = {}
  if opts.title then payload.title = opts.title end
  if opts.body ~= nil then payload.body = opts.body end
  if opts.labels then payload.labels = opts.labels end
  if opts.state then payload.state = opts.state end
  local _, err = api_json(root, remote, path, "PATCH", payload)
  if err then return false, err end
  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return boolean, string|nil
function M.close_issue(root, remote, number) return M.update_issue(root, remote, number, { state = "closed" }) end

---@param root string
---@param remote { owner: string, repo: string }
---@param _ integer|string
---@param comment_id string|integer
---@param body string
---@return boolean, string|nil
function M.update_comment(root, remote, _, comment_id, body)
  if not M.available() then return false, "gh is not on PATH" end
  if tostring(comment_id):match("^review%-") then return false, "Review summary comments cannot be edited here" end
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local path = string.format("repos/%s/%s/issues/comments/%s", remote.owner, remote.repo, tostring(comment_id))
  local _, err = api_json(root, remote, path, "PATCH", { body = body })
  if err then return false, err end
  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@param _ integer|string
---@param comment_id string|integer
---@return boolean, string|nil
function M.delete_comment(root, remote, _, comment_id)
  if not M.available() then return false, "gh is not on PATH" end
  if tostring(comment_id):match("^review%-") then return false, "Review summary comments cannot be deleted here" end
  local path = string.format("repos/%s/%s/issues/comments/%s", remote.owner, remote.repo, tostring(comment_id))
  local _, err = api_json(root, remote, path, "DELETE")
  if err then return false, err end
  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@param opts? { branch?: string, limit?: integer }
---@return ForgeCiRun[], string|nil
function M.list_ci_runs(root, remote, opts)
  if not M.available() then return {}, "gh is not on PATH" end
  opts = opts or {}
  local path =
    string.format("repos/%s/%s/actions/runs?per_page=%s", remote.owner, remote.repo, tostring(opts.limit or 30))
  if opts.branch and opts.branch ~= "" then path = path .. "&branch=" .. urlencode(opts.branch) end
  local data, err = api_json(root, remote, path)
  if err then return {}, err end
  local runs = (type(data) == "table" and data.workflow_runs) or {}
  local out = {}
  for _, r in ipairs(runs) do
    local status = r.status or ""
    local can_cancel = status == "queued" or status == "in_progress" or status == "waiting" or status == "pending"
    table.insert(out, {
      id = tostring(r.id),
      name = r.name or r.display_title or ("run " .. tostring(r.id)),
      status = status,
      conclusion = r.conclusion,
      url = r.html_url,
      can_cancel = can_cancel,
      branch = r.head_branch,
      head_sha = r.head_sha,
    })
  end
  return out, nil
end

---@param root string
---@param remote { owner: string, repo: string }
---@param run_id string|integer
---@return boolean, string|nil
function M.cancel_ci_run(root, remote, run_id)
  if not M.available() then return false, "gh is not on PATH" end
  local path = string.format("repos/%s/%s/actions/runs/%s/cancel", remote.owner, remote.repo, tostring(run_id))
  local _, err = api_json(root, remote, path, "POST", {})
  if err then return false, err end
  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@return ForgeWorkflow[], string|nil
function M.list_triggerable_workflows(root, remote)
  if not M.available() then return {}, "gh is not on PATH" end
  local path = string.format("repos/%s/%s/actions/workflows?per_page=100", remote.owner, remote.repo)
  local data, err = api_json(root, remote, path)
  if err then return {}, err end
  local workflows = (type(data) == "table" and data.workflows) or {}
  local out = {}
  for _, w in ipairs(workflows) do
    if w.state == "active" then
      table.insert(out, {
        id = tostring(w.id),
        name = w.name or w.path or tostring(w.id),
        path = w.path,
        can_dispatch = true,
      })
    end
  end
  return out, nil
end

---@param root string
---@param remote { owner: string, repo: string }
---@param opts { workflow_id: string|integer, ref?: string, inputs?: table }
---@return boolean, string|nil
function M.trigger_ci(root, remote, opts)
  if not M.available() then return false, "gh is not on PATH" end
  opts = opts or {}
  if not opts.workflow_id then return false, "workflow_id required" end
  local ref = opts.ref or "main"
  local path =
    string.format("repos/%s/%s/actions/workflows/%s/dispatches", remote.owner, remote.repo, tostring(opts.workflow_id))
  local payload = { ref = ref, inputs = opts.inputs or {} }
  local _, err = api_json(root, remote, path, "POST", payload)
  if err then return false, err end
  return true
end

return M
