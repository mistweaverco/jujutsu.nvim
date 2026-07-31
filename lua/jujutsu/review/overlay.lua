local M = {}

local ns = vim.api.nvim_create_namespace("jujutsu_review_comments")

---@param buf integer|nil
function M.clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

---@param comments table[]
---@param path string
---@param side "LEFT"|"RIGHT"
---@return table<integer, table[]>
local function by_line(comments, path, side)
  local map = {}
  for _, c in ipairs(comments) do
    local kind = c.kind or "line"
    if c.path == path and (kind == "line" or kind == "range") and c.line then
      local cside = c.side or "RIGHT"
      if cside == side then
        local line = tonumber(c.line) or c.line
        map[line] = map[line] or {}
        table.insert(map[line], c)
      end
    end
  end
  return map
end

---@param c table
---@return string, string hl
local function preview_for(c)
  local body = (c.body or ""):gsub("\n", " ")
  if #body > 80 then body = body:sub(1, 77) .. "..." end
  if c.remote then
    local author = c.author or "remote"
    local stale = c.outdated and " (outdated)" or ""
    return string.format("@%s%s: %s", author, stale, body), "JujutsuReviewRemote"
  end
  return body, "JujutsuReviewComment"
end

---@param buf integer
---@param comments table[]
---@param path string
---@param side "LEFT"|"RIGHT"
function M.render(buf, comments, path, side)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  M.clear(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local grouped = by_line(comments, path, side)
  for line, list in pairs(grouped) do
    if line >= 1 and line <= line_count then
      local virt = {}
      local has_local = false
      for _, c in ipairs(list) do
        local text, hl = preview_for(c)
        if not c.remote then has_local = true end
        table.insert(virt, { { "  💬 " .. text, hl } })
      end
      local sign_hl = has_local and "JujutsuReviewSign" or "JujutsuReviewRemoteSign"
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
        sign_text = "💬",
        sign_hl_group = sign_hl,
        virt_lines = virt,
        virt_lines_above = false,
        priority = 1100,
      })
    end
  end
end

---@param comments table[]
---@param path string
---@param side "LEFT"|"RIGHT"
---@param from_line integer
---@param direction integer 1 or -1
---@return integer|nil
function M.next_comment_line(comments, path, side, from_line, direction)
  local lines = {}
  for line, _ in pairs(by_line(comments, path, side)) do
    table.insert(lines, line)
  end
  table.sort(lines)
  if #lines == 0 then return nil end
  if direction > 0 then
    for _, l in ipairs(lines) do
      if l > from_line then return l end
    end
    return lines[1]
  else
    for i = #lines, 1, -1 do
      if lines[i] < from_line then return lines[i] end
    end
    return lines[#lines]
  end
end

return M
