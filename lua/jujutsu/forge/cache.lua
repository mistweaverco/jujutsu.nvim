local M = {}

---@type table<string, any[]>
local store = {}

---@type integer
local refresh_depth = 0

---@param value any
---@return any
local function deepcopy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepcopy(v)
  end
  return out
end

---@return boolean
function M.refreshing() return refresh_depth > 0 end

---Run fn while bypassing the cache; fresh results are stored.
---@param fn fun()
---@return ...
function M.with_refresh(fn)
  refresh_depth = refresh_depth + 1
  local ok, err = pcall(fn)
  refresh_depth = refresh_depth - 1
  if not ok then error(err) end
end

---Drop all cached forge HTTP / gh / glab / forgejo / bitbucket responses.
function M.clear() store = {} end

---@param method string|nil
---@return boolean
function M.is_http_read(method)
  local method_upper = (method or "GET"):upper()
  return method_upper == "GET" or method_upper == "HEAD"
end

---@param prefix string
---@param ... string|number|boolean
---@return string
function M.key(prefix, ...)
  local parts = { prefix }
  for i = 1, select("#", ...) do
    table.insert(parts, tostring(select(i, ...)))
  end
  return table.concat(parts, "\0")
end

---@param prefix string
---@param root string
---@param args string[]
---@param stdin? string
---@return string
function M.key_args(prefix, root, args, stdin)
  local parts = { prefix, root }
  for _, arg in ipairs(args or {}) do
    table.insert(parts, arg)
  end
  if stdin and stdin ~= "" then table.insert(parts, stdin) end
  return table.concat(parts, "\0")
end

---@param headers table<string, string>|nil
---@return string
function M.key_headers(headers)
  if not headers then return "" end
  local keys = vim.tbl_keys(headers)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, k .. "=" .. tostring(headers[k]))
  end
  return table.concat(parts, "\0")
end

---@param _ "gh"|"glab"
---@param args string[]
---@return boolean
function M.is_read_only(_, args)
  if not args or #args == 0 then return false end

  if args[1] == "api" then
    for i = 1, #args - 1 do
      if args[i] == "-X" then
        local method = args[i + 1]
        return method == "GET" or method == nil
      end
    end
    return true
  end

  local write_verbs = {
    create = true,
    merge = true,
    close = true,
    delete = true,
    edit = true,
    comment = true,
    review = true,
    update = true,
    reopen = true,
    submit = true,
    trigger = true,
    cancel = true,
  }
  for i = 2, math.min(3, #args) do
    if write_verbs[args[i]] then return false end
  end

  -- glab uses "mr" / "issue" then subcommand; gh uses "pr" / "issue" etc.
  return true
end

---@param ... any
---@return table
local function pack_results(...) return { n = select("#", ...), ... } end

---@param cache_key string
---@param fetch fun(): ...
---@return ...
function M.fetch(cache_key, fetch)
  if refresh_depth == 0 then
    local hit = store[cache_key]
    if hit ~= nil then
      local copy = deepcopy(hit)
      return unpack(copy, 1, copy.n)
    end
  end

  local results = pack_results(fetch())
  store[cache_key] = deepcopy(results)
  return unpack(results, 1, results.n)
end

return M
