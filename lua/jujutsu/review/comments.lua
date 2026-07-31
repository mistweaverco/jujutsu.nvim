local M = {}

---@alias ReviewCommentKind "line"|"range"|"file"|"review"
---@alias ReviewCommentSide "LEFT"|"RIGHT"

---@class ReviewComment
---@field id string
---@field kind ReviewCommentKind
---@field path? string
---@field side? ReviewCommentSide
---@field line? integer
---@field start_line? integer
---@field body string
---@field created_at integer

-- luacheck: ignore 631
---@param opts? { kind?: ReviewCommentKind, path?: string, side?: ReviewCommentSide, line?: integer, start_line?: integer, body?: string }
---@return ReviewComment
function M.new(opts)
  opts = opts or {}
  return {
    id = string.format("%s-%d", tostring(vim.uv.hrtime()), math.random(1000, 9999)),
    kind = opts.kind or "line",
    path = opts.path,
    side = opts.side,
    line = opts.line,
    start_line = opts.start_line,
    body = opts.body or "",
    created_at = os.time(),
  }
end

---@param comment ReviewComment
---@return string
function M.anchor_label(comment)
  if comment.kind == "review" then return "(review)" end
  if comment.kind == "file" then return comment.path or "(file)" end
  local path = comment.path or "?"
  if comment.kind == "range" and comment.start_line and comment.line then
    return string.format("%s:%d-%d", path, comment.start_line, comment.line)
  end
  if comment.line then return string.format("%s:%d", path, comment.line) end
  return path
end

---@param comments ReviewComment[]
---@param title? string
---@return string
function M.to_markdown(comments, title)
  local lines = {
    "I reviewed your code and have the following comments. Please address them.",
    "",
  }
  if title and title ~= "" then
    table.insert(lines, 2, string.format("Review: %s", title))
    table.insert(lines, 3, "")
  end
  for i, c in ipairs(comments) do
    local anchor = M.anchor_label(c)
    local body = (c.body or ""):gsub("%s+$", "")
    table.insert(lines, string.format("%d. %s - %s", i, anchor, body))
  end
  return table.concat(lines, "\n")
end

---@param comments ReviewComment[]
---@return { path: string, body: string, line?: integer, side?: string, start_line?: integer, start_side?: string }[]
function M.to_provider_comments(comments)
  local out = {}
  for _, c in ipairs(comments) do
    if (c.kind == "line" or c.kind == "range") and c.path and c.line then
      local entry = {
        path = c.path,
        body = c.body or "",
        line = c.line,
        side = c.side or "RIGHT",
      }
      if c.kind == "range" and c.start_line and c.start_line < c.line then
        entry.start_line = c.start_line
        entry.start_side = c.side or "RIGHT"
      end
      table.insert(out, entry)
    end
  end
  return out
end

---@param comments ReviewComment[]
---@return string
function M.review_body(comments)
  local parts = {}
  for _, c in ipairs(comments) do
    if c.kind == "review" or c.kind == "file" then
      local label = c.kind == "file" and M.anchor_label(c) or "Review"
      table.insert(parts, string.format("%s - %s", label, c.body or ""))
    end
  end
  return table.concat(parts, "\n\n")
end

return M
