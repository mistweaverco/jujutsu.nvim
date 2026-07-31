local M = {}

---@return boolean
function M.available() return vim.fn.executable("gh") == 1 end

---@param root string
---@param args string[]
---@return { code: integer, stdout: string, stderr: string }
local function run(root, args)
  local obj = vim.system(vim.list_extend({ "gh" }, args), { cwd = root, text = true }):wait()
  return { code = obj.code, stdout = obj.stdout or "", stderr = obj.stderr or "" }
end

---@param root string
-- luacheck: ignore 631
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

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return ForgeRemoteComment[]
function M.list_review_comments(root, remote, number)
  if not M.available() then return {} end
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
    local line = c.line or c.original_line
    local path = c.path
    if path and line then
      local side = c.side or "RIGHT"
      if side ~= "LEFT" and side ~= "RIGHT" then side = "RIGHT" end
      table.insert(out, {
        id = "remote-" .. tostring(c.id),
        path = path,
        side = side,
        line = tonumber(line) or line,
        start_line = c.start_line or c.original_start_line,
        body = c.body or "",
        author = (c.user and (c.user.login or c.user.name)) or "unknown",
        outdated = c.line == nil and c.original_line ~= nil,
        url = c.html_url,
        remote = true,
        kind = "line",
      })
    end
  end
  return out
end

return M
