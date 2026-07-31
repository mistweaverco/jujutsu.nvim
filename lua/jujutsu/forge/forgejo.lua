local config = require("jujutsu.config")
local http = require("jujutsu.forge.http")

local M = {}

---@return string|nil
local function token()
  local fj = (config.values.forge and config.values.forge.forgejo) or {}
  local t = fj.token or vim.env.FORGEJO_TOKEN or vim.env.CODEBERG_TOKEN
  if t and t ~= "" then return t end
  return nil
end

---@return boolean
function M.available() return token() ~= nil and vim.fn.executable("curl") == 1 end

---@param remote { host: string }
---@return string
local function api_base(remote) return string.format("https://%s/api/v1", remote.host) end

---@param remote { host: string, owner: string, repo: string }
---@param method string
---@param path string
---@param body? table
---@return table|nil, string|nil
local function api(remote, method, path, body)
  local t = token()
  if not t then return nil, "Forgejo/Codeberg token missing (forge.forgejo.token or FORGEJO_TOKEN/CODEBERG_TOKEN)" end
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
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[]
function M.list_prs(_root, remote)
  if not M.available() then return {} end
  local data, err =
    api(remote, "GET", string.format("/repos/%s/%s/pulls?state=open&limit=50", remote.owner, remote.repo))
  if err or type(data) ~= "table" then return {} end
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
  return out
end

---@param _root string
---@param remote { host: string, owner: string, repo: string }
---@param number integer|string
---@return table|nil, string|nil
function M.get_pr(_root, remote, number)
  if not M.available() then return nil, "Forgejo/Codeberg token missing or curl unavailable" end
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
  if not M.available() then return false, "Forgejo/Codeberg token missing or curl unavailable" end
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
  if not M.available() then return {} end
  local data, err =
    api(remote, "GET", string.format("/repos/%s/%s/pulls/%s/comments", remote.owner, remote.repo, tostring(number)))
  if err or type(data) ~= "table" then return {} end
  local out = {}
  for _, c in ipairs(data) do
    local line = c.position or c.line or c.new_position or c.new_line or c.old_line
    local path = c.path
    if path and line and line ~= 0 then
      local side = "RIGHT"
      if c.old_line and (not c.new_line or c.new_line == 0) then side = "LEFT" end
      table.insert(out, {
        id = "remote-" .. tostring(c.id),
        path = path,
        side = side,
        line = tonumber(line) or line,
        body = c.body or "",
        author = (c.user and (c.user.login or c.user.username)) or "unknown",
        outdated = false,
        url = c.html_url,
        remote = true,
        kind = "line",
      })
    end
  end
  return out
end

return M
