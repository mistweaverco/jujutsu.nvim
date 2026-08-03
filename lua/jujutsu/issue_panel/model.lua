local M = {}

---Coerce JSON null / non-strings from forge APIs into a plain string.
---@param value any
---@param fallback? string
---@return string
function M.as_string(value, fallback)
  if value == nil or value == vim.NIL then return fallback or "" end
  if type(value) == "string" then return value end
  if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
  return fallback or ""
end

---@param iso any
---@return string
function M.format_time(iso)
  iso = M.as_string(iso)
  if iso == "" then return "" end
  -- Keep ISO date readable; strip fractional seconds / Z noise lightly.
  local date = iso:match("^(%d%d%d%d%-%d%d%-%d%d)")
  local time = iso:match("T(%d%d:%d%d)")
  if date and time then return date .. " " .. time end
  return iso
end

---@param state any
---@return string
function M.state_label(state)
  state = string.lower(M.as_string(state, "open"))
  if state == "opened" then return "open" end
  return state
end

---@param list any
---@return string[]
local function as_string_list(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for _, item in ipairs(list) do
    local s = M.as_string(item)
    if s ~= "" then table.insert(out, s) end
  end
  return out
end

---@param topic ForgeTopic
---@param comments ForgeConversationComment[]
---@return { topic: ForgeTopic, comments: ForgeConversationComment[] }
function M.normalize(topic, comments)
  topic.labels = as_string_list(topic.labels)
  topic.assignees = as_string_list(topic.assignees)
  topic.body = M.as_string(topic.body)
  topic.title = M.as_string(topic.title)
  topic.author = M.as_string(topic.author, "unknown")
  topic.repo = M.as_string(topic.repo)
  topic.url = M.as_string(topic.url)
  topic.created_at = M.as_string(topic.created_at)
  topic.updated_at = M.as_string(topic.updated_at)
  topic.state = M.state_label(topic.state)
  topic.number = topic.number
  comments = comments or {}
  for _, c in ipairs(comments) do
    c.body = M.as_string(c.body)
    c.author = M.as_string(c.author, "unknown")
    c.author_association = M.as_string(c.author_association)
    c.created_at = M.as_string(c.created_at)
    c.updated_at = M.as_string(c.updated_at)
    c.url = M.as_string(c.url)
    c.id = M.as_string(c.id, "?")
  end
  return { topic = topic, comments = comments }
end

return M
