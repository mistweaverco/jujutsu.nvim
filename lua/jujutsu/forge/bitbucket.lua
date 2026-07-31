local config = require("jujutsu.config")
local http = require("jujutsu.forge.http")

local M = {}

local API_BASE = "https://api.bitbucket.org/2.0"

---@return string|nil, string|nil, string|nil
local function credentials()
  local bb = (config.values.forge and config.values.forge.bitbucket) or {}
  local user = bb.user or vim.env.BITBUCKET_USER
  local token = bb.token or vim.env.BITBUCKET_TOKEN
  if not user or user == "" or not token or token == "" then
    return nil, nil, "Missing Bitbucket credentials (forge.bitbucket.user/token or BITBUCKET_USER/BITBUCKET_TOKEN)"
  end
  return user, token, nil
end

---@return boolean
function M.available()
  local user, token = credentials()
  return user ~= nil and token ~= nil and vim.fn.executable("curl") == 1
end

---@param method string
---@param path_or_url string
---@param body? table
---@return table|nil, string|nil
local function api(method, path_or_url, body)
  local user, token, auth_err = credentials()
  if auth_err then return nil, auth_err end
  local url = path_or_url
  if not url:match("^https?://") then
    if url:sub(1, 1) ~= "/" then url = "/" .. url end
    url = API_BASE .. url
  end
  if type(user) ~= "string" or user == "" or type(token) ~= "string" or token == "" then
    return nil, "Missing Bitbucket credentials (forge.bitbucket.user/token or BITBUCKET_USER/BITBUCKET_TOKEN)"
  end
  local headers = {
    Authorization = http.basic_auth(user, token),
    Accept = "application/json",
    ["Content-Type"] = body and "application/json" or nil,
  }
  local res = http.request(method, url, headers, body and vim.json.encode(body) or nil)
  if res.err then return nil, res.err end
  return res.json or {}, nil
end

---@param url string
---@return table[]
local function fetch_all(url)
  local values = {}
  local next_url = url
  while next_url and next_url ~= "" do
    local result, err = api("GET", next_url)
    if err or not result then break end
    for _, v in ipairs(result.values or {}) do
      table.insert(values, v)
    end
    next_url = type(result.next) == "string" and result.next or ""
  end
  return values
end

---@param _ string
---@param remote { owner: string, repo: string }
-- luacheck: ignore 631
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[]
function M.list_prs(_, remote)
  if not M.available() then return {} end
  local endpoint = string.format("/repositories/%s/%s/pullrequests?state=OPEN&pagelen=50", remote.owner, remote.repo)
  local values = fetch_all(endpoint)
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
  return out
end

---@param _root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return table|nil, string|nil
function M.get_pr(_root, remote, number)
  if not M.available() then return nil, "Bitbucket credentials missing or curl unavailable" end
  local pr, err =
    api("GET", string.format("/repositories/%s/%s/pullrequests/%s", remote.owner, remote.repo, tostring(number)))
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

---@param _root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@param opts { event?: string, body?: string, comments?: { path: string, body: string, line?: integer, side?: string, start_line?: integer }[] }
---@return boolean, string|nil
function M.submit_review(root, remote, number, opts)
  if not M.available() then return false, "Bitbucket credentials missing or curl unavailable" end
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
    local _, cerr = api("POST", comments_url, payload)
    if cerr then return false, cerr end
  end

  if opts.body and opts.body ~= "" then
    local _, cerr = api("POST", comments_url, { content = { raw = opts.body } })
    if cerr then return false, cerr end
  end

  local event = opts.event or "COMMENT"
  if event == "APPROVE" then
    local _, aerr = api(
      "POST",
      string.format("/repositories/%s/%s/pullrequests/%s/approve", remote.owner, remote.repo, tostring(number)),
      {}
    )
    if aerr then return false, aerr end
  elseif event == "REQUEST_CHANGES" then
    local _, rerr = api(
      "POST",
      string.format("/repositories/%s/%s/pullrequests/%s/request-changes", remote.owner, remote.repo, tostring(number)),
      {}
    )
    if rerr then return false, rerr end
  end

  return true
end

---@param root string
---@param remote { owner: string, repo: string }
---@param number integer|string
---@return ForgeRemoteComment[]
function M.list_review_comments(root, remote, number)
  if not M.available() then return {} end
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

  local values = fetch_all(comments_url)
  local out = {}
  for _, c in ipairs(values) do
    local inline = c.inline
    if type(inline) == "table" and inline.path then
      local side, line
      if inline.to then
        side, line = "RIGHT", inline.to
      elseif inline.from then
        side, line = "LEFT", inline.from
      end
      if line then
        local author = "unknown"
        if c.user then author = c.user.display_name or c.user.nickname or c.user.uuid or author end
        local body = ""
        if type(c.content) == "table" then
          body = c.content.raw or c.content.markup or ""
        elseif type(c.content) == "string" then
          body = c.content
        end
        table.insert(out, {
          id = "remote-" .. tostring(c.id),
          path = inline.path,
          side = side,
          line = tonumber(line) or line,
          start_line = inline.start_to or inline.start_from,
          body = body,
          author = author,
          outdated = false,
          url = c.links and c.links.html and c.links.html.href or nil,
          remote = true,
          kind = "line",
        })
      end
    end
  end
  return out
end

return M
