local M = {}

---@return boolean
function M.available() return vim.fn.executable("glab") == 1 end

---@param root string
---@param args string[]
---@param input? string
---@return { code: integer, stdout: string, stderr: string }
local function run(root, args, input)
  local obj = vim
    .system(vim.list_extend({ "glab" }, args), {
      cwd = root,
      text = true,
      stdin = input,
    })
    :wait()
  return { code = obj.code, stdout = obj.stdout or "", stderr = obj.stderr or "" }
end

---@param root string
---@param remote { host: string, owner: string, repo: string }
-- luacheck: ignore 631
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[]
function M.list_prs(root, remote)
  if not M.available() then return {} end
  local project = remote.owner .. "/" .. remote.repo
  local res = run(root, {
    "mr",
    "list",
    "--repo",
    project,
    "-F",
    "json",
    "--per-page",
    "50",
  })
  if res.code ~= 0 then
    -- fallback without --repo
    res = run(root, { "mr", "list", "-F", "json", "--per-page", "50" })
  end
  if res.code ~= 0 then return {} end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for _, mr in ipairs(data) do
    local iid = mr.iid or mr.number
    local web = mr.web_url or mr.url or ""
    table.insert(out, {
      number = iid,
      title = mr.title or "",
      url = web,
      head_ref = (mr.source_branch or mr.head_ref or ""),
      base_ref = (mr.target_branch or mr.base_ref or ""),
      head_sha = (mr.sha or (mr.diff_refs and mr.diff_refs.head_sha) or ""),
      base_sha = ((mr.diff_refs and mr.diff_refs.base_sha) or ""),
    })
  end
  return out
end

---@param s string
---@return string
local function urlencode_path(s)
  return (
    s:gsub("([^%w%-%._~])", function(c)
      if c == "/" then return "%2F" end
      return string.format("%%%02X", string.byte(c))
    end)
  )
end

---@param root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@return table|nil, string|nil
function M.get_pr(root, remote, number)
  if not M.available() then return nil, "glab is not on PATH" end
  local project = remote.owner .. "/" .. remote.repo
  local encoded = urlencode_path(project)
  local path = string.format("projects/%s/merge_requests/%s", encoded, tostring(number))
  local res = run(root, { "api", path })
  if res.code ~= 0 then return nil, res.stderr ~= "" and res.stderr or "failed to fetch MR" end
  local ok, mr = pcall(vim.json.decode, res.stdout)
  if not ok or type(mr) ~= "table" then return nil, "invalid MR JSON" end
  return {
    number = mr.iid or number,
    title = mr.title or "",
    url = mr.web_url or "",
    head_ref = mr.source_branch or "",
    base_ref = mr.target_branch or "",
    head_sha = mr.sha or (mr.diff_refs and mr.diff_refs.head_sha) or "",
    base_sha = (mr.diff_refs and mr.diff_refs.base_sha) or "",
    body = mr.description or "",
  }
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param method string
---@param path string
---@param body? table
---@return table|nil, string|nil
local function api(root, remote, number, method, path, body)
  local project = urlencode_path(remote.owner .. "/" .. remote.repo)
  local endpoint = string.format("projects/%s/merge_requests/%s%s", project, tostring(number), path)
  local args = { "api", "--method", method, endpoint }
  local input = nil
  if body then
    table.insert(args, "--input")
    table.insert(args, "-")
    input = vim.json.encode(body)
  end
  local res = run(root, args, input)
  if res.code ~= 0 then return nil, res.stderr ~= "" and res.stderr or res.stdout end
  if res.stdout == "" then return {}, nil end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if ok then return data end
  return {}, nil
end

---Submit review: post inline discussions, optional summary note, then approve/request-changes.
---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { event?: string, body?: string, comments?: { path: string, body: string, line?: integer, side?: string, start_line?: integer, new_path?: string, old_path?: string, new_line?: integer, old_line?: integer }[] }
---@return boolean, string|nil
function M.submit_review(root, remote, number, opts)
  if not M.available() then return false, "glab is not on PATH" end
  opts = opts or {}
  if opts.event == "DRAFT" then return false, "Draft reviews are GitHub-only" end

  for _, c in ipairs(opts.comments or {}) do
    local position = {
      position_type = "text",
      new_path = c.path,
      old_path = c.path,
    }
    if c.side == "LEFT" then
      position.old_line = c.line
      position.new_line = nil
    else
      position.new_line = c.line
    end
    if c.start_line and c.line and c.start_line ~= c.line then
      if c.side == "LEFT" then
        position.old_line = c.line
        -- GitLab range via line_range when supported
        position.line_range = {
          start = { type = "old", old_line = c.start_line },
          ["end"] = { type = "old", old_line = c.line },
        }
      else
        position.line_range = {
          start = { type = "new", new_line = c.start_line },
          ["end"] = { type = "new", new_line = c.line },
        }
      end
    end
    local _, err = api(root, remote, number, "POST", "/discussions", {
      body = c.body,
      position = position,
    })
    if err then return false, err end
  end

  if opts.body and opts.body ~= "" then
    local _, err = api(root, remote, number, "POST", "/notes", { body = opts.body })
    if err then return false, err end
  end

  local event = opts.event or "COMMENT"
  if event == "APPROVE" then
    local _, err = api(root, remote, number, "POST", "/approve", {})
    if err then return false, err end
  elseif event == "REQUEST_CHANGES" then
    -- GitLab: set reviewer state via /reviews if available
    local _, err = api(root, remote, number, "PUT", "/reviewers/me", {
      state_event = "request_changes",
    })
    if err then
      -- fallback older API
      local _, err2 = api(root, remote, number, "POST", "/reviews", {
        event = "request_changes",
      })
      if err2 then return false, err end
    end
  end

  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return ForgeRemoteComment[]
function M.list_review_comments(root, remote, number)
  if not M.available() then return {} end
  local threads = require("jujutsu.review.threads")
  local data, err = api(root, remote, number, "GET", "/discussions")
  if err or type(data) ~= "table" then return {} end
  local out = {}
  for _, disc in ipairs(data) do
    local discussion_id = disc.id and tostring(disc.id) or nil
    local root_id = nil
    local root_loc = nil
    for _, note in ipairs(disc.notes or {}) do
      if not note.system then
        local path, line, side
        local pos = note.position
        if type(pos) == "table" then
          path = pos.new_path or pos.old_path
          if pos.new_line and pos.new_line ~= vim.NIL then
            line = pos.new_line
            side = "RIGHT"
          elseif pos.old_line and pos.old_line ~= vim.NIL then
            line = pos.old_line
            side = "LEFT"
          end
        end
        if (not path or not line) and root_loc then
          path = path or root_loc.path
          line = line or root_loc.line
          side = side or root_loc.side
        end
        if path and line then
          local id = threads.remote_id(note.id)
          local parent_id = root_id
          if not root_id then
            root_id = id
            root_loc = { path = path, line = line, side = side }
            parent_id = nil
          end
          table.insert(out, {
            id = id,
            path = path,
            side = side,
            line = tonumber(line) or line,
            body = note.body or "",
            author = (note.author and (note.author.username or note.author.name)) or "unknown",
            outdated = type(pos) == "table" and pos.outdated == true,
            url = note.web_url,
            remote = true,
            kind = "line",
            parent_id = parent_id,
            discussion_id = discussion_id,
            provider = "gitlab",
            created_at = note.created_at,
            updated_at = note.updated_at,
            supports_reply = discussion_id ~= nil,
          })
        end
      end
    end
  end
  return out
end

---@param root string
---@param remote { owner: string, repo: string }
---@param resource "merge_requests"|"issues"
---@param number integer|string
---@param method string
---@param path string
---@param body? table
---@return table|nil, string|nil
local function resource_api(root, remote, resource, number, method, path, body)
  local project = urlencode_path(remote.owner .. "/" .. remote.repo)
  local endpoint = string.format("projects/%s/%s/%s%s", project, resource, tostring(number), path)
  local args = { "api", "--method", method, endpoint }
  local input = nil
  if body then
    table.insert(args, "--input")
    table.insert(args, "-")
    input = vim.json.encode(body)
  end
  local res = run(root, args, input)
  if res.code ~= 0 then return nil, res.stderr ~= "" and res.stderr or res.stdout end
  if res.stdout == "" then return {}, nil end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if ok then return data end
  return {}, nil
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
      table.insert(out, l.name or l.title or "?")
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
    if type(u) == "table" then table.insert(out, u.username or u.name or "?") end
  end
  return out
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@return ForgeTopic|nil, string|nil
function M.get_topic(root, remote, number, opts)
  if not M.available() then return nil, "glab is not on PATH" end
  opts = opts or {}
  local kind = opts.kind or "pr"
  if kind == "issue" then
    local issue, err = resource_api(root, remote, "issues", number, "GET", "")
    if err or type(issue) ~= "table" then return nil, err or "failed to fetch issue" end
    return {
      kind = "issue",
      number = issue.iid or number,
      title = issue.title or "",
      body = issue.description or "",
      state = issue.state or "opened",
      author = (issue.author and (issue.author.username or issue.author.name)) or "unknown",
      created_at = issue.created_at,
      updated_at = issue.updated_at,
      labels = map_labels(issue.labels),
      assignees = map_users(issue.assignees),
      url = issue.web_url or "",
      repo = remote.owner .. "/" .. remote.repo,
    }
  end

  local mr, err = resource_api(root, remote, "merge_requests", number, "GET", "")
  if err or type(mr) ~= "table" then return nil, err or "failed to fetch MR" end
  local state = mr.state or "opened"
  if type(mr.merged_at) == "string" and mr.merged_at ~= "" then state = "merged" end
  if mr.draft or mr.work_in_progress then state = "draft" end
  return {
    kind = "pr",
    number = mr.iid or number,
    title = mr.title or "",
    body = mr.description or "",
    state = state,
    draft = mr.draft == true or mr.work_in_progress == true,
    merged = type(mr.merged_at) == "string" and mr.merged_at ~= "",
    author = (mr.author and (mr.author.username or mr.author.name)) or "unknown",
    created_at = mr.created_at,
    updated_at = mr.updated_at,
    labels = map_labels(mr.labels),
    assignees = map_users(mr.assignees),
    url = mr.web_url or "",
    repo = remote.owner .. "/" .. remote.repo,
  }
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@return ForgeConversationComment[], string|nil
function M.list_comments(root, remote, number, opts)
  if not M.available() then return {}, "glab is not on PATH" end
  opts = opts or {}
  local resource = (opts.kind == "issue") and "issues" or "merge_requests"
  local data, err = resource_api(root, remote, resource, number, "GET", "/notes?sort=asc&per_page=100")
  if err then return {}, err end
  if type(data) ~= "table" then return {}, nil end
  local out = {}
  for _, note in ipairs(data) do
    if not note.system and not note.position then
      table.insert(out, {
        id = tostring(note.id),
        author = (note.author and (note.author.username or note.author.name)) or "unknown",
        created_at = note.created_at,
        updated_at = note.updated_at,
        body = note.body or "",
        url = note.web_url,
        kind = "comment",
      })
    end
  end
  return out, nil
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param body string
---@param opts? { kind?: "issue"|"pr" }
---@return boolean, string|nil
function M.post_comment(root, remote, number, body, opts)
  if not M.available() then return false, "glab is not on PATH" end
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  opts = opts or {}
  local resource = (opts.kind == "issue") and "issues" or "merge_requests"
  local _, err = resource_api(root, remote, resource, number, "POST", "/notes", { body = body })
  if err then return false, err end
  return true
end

---Reply inside an MR discussion thread.
---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { discussion_id: string, body: string, parent_id?: string|integer }
---@return boolean, string|nil
function M.post_reply(root, remote, number, opts)
  if not M.available() then return false, "glab is not on PATH" end
  opts = opts or {}
  local body = opts.body
  if not body or vim.trim(body) == "" then return false, "Empty comment" end
  local discussion_id = opts.discussion_id
  if not discussion_id or discussion_id == "" then return false, "Missing discussion id" end
  local _, err =
    api(root, remote, number, "POST", string.format("/discussions/%s/notes", tostring(discussion_id)), { body = body })
  if err then return false, err end
  return true
end

return M
