local M = {}

---Strip the `remote-` prefix used in DiffView comment ids.
---@param id string|integer|nil
---@return string|nil
function M.raw_id(id)
  if id == nil then return nil end
  local s = tostring(id)
  return (s:gsub("^remote%-", ""))
end

---@param id string|integer|nil
---@return string
function M.remote_id(id) return "remote-" .. tostring(id) end

---Order comments for a line: roots first, then replies under each root.
---@param comments table[]
---@return table[]
function M.order_for_overlay(comments)
  local by_id = {}
  for _, c in ipairs(comments) do
    if c.id then by_id[c.id] = c end
  end

  local roots = {}
  local children = {}
  for _, c in ipairs(comments) do
    local parent = c.parent_id
    if parent and by_id[parent] then
      children[parent] = children[parent] or {}
      table.insert(children[parent], c)
    else
      table.insert(roots, c)
    end
  end

  local function by_time(a, b)
    local ta = a.created_at or a.updated_at or ""
    local tb = b.created_at or b.updated_at or ""
    if ta ~= tb then return ta < tb end
    return tostring(a.id or "") < tostring(b.id or "")
  end
  table.sort(roots, by_time)

  local out = {}
  local function push_thread(root, depth)
    local copy = vim.tbl_extend("force", {}, root)
    copy._thread_depth = depth
    table.insert(out, copy)
    local kids = children[root.id] or {}
    table.sort(kids, by_time)
    for _, kid in ipairs(kids) do
      push_thread(kid, depth + 1)
    end
  end
  for _, root in ipairs(roots) do
    push_thread(root, 0)
  end
  return out
end

---True when a forge comment can be replied to via the API.
---@param c table|nil
---@return boolean
function M.can_reply(c)
  if not c or not c.remote then return false end
  if c.supports_reply == false then return false end
  -- GitLab replies need the discussion id.
  if c.provider == "gitlab" then return c.discussion_id ~= nil and c.discussion_id ~= "" end
  return c.id ~= nil
end

---Fill path/line/side from the nearest ancestor that has them (Bitbucket/GitLab replies).
---@param items table[]
function M.inherit_locations(items)
  local by_id = {}
  for _, c in ipairs(items) do
    if c.id then by_id[c.id] = c end
  end
  for _, item in ipairs(items) do
    if item.parent_id and (not item.path or not item.line) then
      local cur = by_id[item.parent_id]
      local guard = 0
      while cur and guard < 32 do
        guard = guard + 1
        if cur.path and cur.line then
          item.path = item.path or cur.path
          item.line = item.line or cur.line
          item.side = item.side or cur.side
          item.start_line = item.start_line or cur.start_line
          break
        end
        cur = cur.parent_id and by_id[cur.parent_id] or nil
      end
    end
  end
end

return M
