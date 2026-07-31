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
  local data, err = api(root, remote, number, "GET", "/discussions")
  if err or type(data) ~= "table" then return {} end
  local out = {}
  for _, disc in ipairs(data) do
    for _, note in ipairs(disc.notes or {}) do
      local pos = note.position
      if not note.system and type(pos) == "table" then
        local path = pos.new_path or pos.old_path
        local line, side
        if pos.new_line and pos.new_line ~= vim.NIL then
          line = pos.new_line
          side = "RIGHT"
        elseif pos.old_line and pos.old_line ~= vim.NIL then
          line = pos.old_line
          side = "LEFT"
        end
        if path and line then
          table.insert(out, {
            id = "remote-" .. tostring(note.id),
            path = path,
            side = side,
            line = tonumber(line) or line,
            body = note.body or "",
            author = (note.author and (note.author.username or note.author.name)) or "unknown",
            outdated = pos.outdated == true,
            url = note.web_url,
            remote = true,
            kind = "line",
          })
        end
      end
    end
  end
  return out
end

return M
