---Highlight markdown text via a hidden scratch buffer + treesitter.
---Used to project `@markup.*` (and injected language) captures onto virt_lines.

local M = {}

---@type integer|nil
local scratch = nil

---@return integer|nil
local function ensure_scratch()
  if scratch and vim.api.nvim_buf_is_valid(scratch) then return scratch end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_name, buf, string.format("jujutsu://markdown-scratch/%d", buf))
  scratch = buf
  return buf
end

---@param srow integer
---@param scol integer
---@param erow integer
---@param ecol integer
---@param line integer 0-based
---@param line_len integer
---@return integer|nil from 0-based inclusive
---@return integer|nil to 0-based exclusive
local function clip_range(srow, scol, erow, ecol, line, line_len)
  if erow < line or srow > line then return nil end
  if srow == erow then
    if srow ~= line then return nil end
    return scol, ecol
  end
  local from = srow < line and 0 or scol
  local to = erow > line and line_len or ecol
  if from >= to then return nil end
  return from, to
end

---@param line_text string
---@param hl_at (integer|nil)[] 1-based byte -> hl id
---@param conceal_at boolean[] 1-based byte -> concealed?
---@return { [1]: string, [2]: integer|nil }[]
local function coalesce_line(line_text, hl_at, conceal_at)
  local chunks = {}
  local i = 1
  local len = #line_text
  while i <= len do
    if conceal_at[i] then
      i = i + 1
    else
      local hl = hl_at[i]
      local j = i + 1
      while j <= len and not conceal_at[j] and hl_at[j] == hl do
        j = j + 1
      end
      table.insert(chunks, { line_text:sub(i, j - 1), hl })
      i = j
    end
  end
  if #chunks == 0 then return { { "", nil } } end
  return chunks
end

---Parse `text` as markdown in a hidden buffer and return per-line virt_text chunks.
---Concealed marker bytes (e.g. `**`) are omitted so bodies read as rendered markdown.
---@param text string
---@return { [1]: string, [2]: integer|nil }[][]|nil lines of chunks, or nil if TS unavailable
function M.highlight_lines(text)
  local buf = ensure_scratch()
  if not buf then return nil end

  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then lines = { "" } end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  if not pcall(vim.treesitter.start, buf, "markdown") then return nil end
  local parser = vim.treesitter.get_parser(buf, "markdown")
  if not parser then return nil end
  pcall(function() parser:parse(true) end)

  local highlighter = vim.treesitter.highlighter.active[buf]
  if not highlighter then return nil end

  local ts_priority = (vim.hl and vim.hl.priorities and vim.hl.priorities.treesitter)
    or (vim.highlight and vim.highlight.priorities and vim.highlight.priorities.treesitter)
    or 100

  ---@type (integer|nil)[][]
  local hl_at = {}
  ---@type integer[][]
  local pri_at = {}
  ---@type boolean[][]
  local conceal_at = {}
  for i, line in ipairs(lines) do
    hl_at[i] = {}
    pri_at[i] = {}
    conceal_at[i] = {}
    for b = 1, #line do
      hl_at[i][b] = nil
      pri_at[i][b] = -1
      conceal_at[i][b] = false
    end
  end

  local function paint(line_idx, from, to, hl, priority, conceal)
    if not hl or hl == 0 then
      if conceal then
        for b = from + 1, to do
          conceal_at[line_idx][b] = true
        end
      end
      return
    end
    for b = from + 1, to do
      if conceal then
        conceal_at[line_idx][b] = true
      elseif priority >= (pri_at[line_idx][b] or -1) then
        pri_at[line_idx][b] = priority
        hl_at[line_idx][b] = hl
      end
    end
  end

  highlighter.tree:for_each_tree(function(tstree, ltree)
    if not tstree then return end
    local lang = ltree:lang()
    ---@diagnostic disable-next-line: invisible
    local hq = highlighter:get_query(lang)
    local query = hq and hq:query()
    if not query then return end

    for capture, node, metadata in query:iter_captures(tstree:root(), buf, 0, -1) do
      local name = query.captures[capture]
      if not name or name:match("^_") or name == "spell" or name == "nospell" then goto continue end

      local range = { node:range() }
      if metadata and metadata[capture] and metadata[capture].range then
        range = metadata[capture].range
      elseif type(vim.treesitter.get_range) == "function" then
        local ok, r = pcall(vim.treesitter.get_range, node, buf, metadata and metadata[capture])
        if ok and r then range = { r[1], r[2], r[4], r[5] } end
      end
      local srow, scol, erow, ecol = range[1], range[2], range[3], range[4]

      local priority = ts_priority
      if metadata then
        priority = tonumber(metadata.priority or (metadata[capture] and metadata[capture].priority)) or priority
      end

      local conceal = name == "conceal"
        or (metadata and (metadata.conceal or (metadata[capture] and metadata[capture].conceal))) ~= nil

      ---@diagnostic disable-next-line: invisible
      local hl = hq:get_hl_from_capture(capture)

      for line = srow, erow do
        local line_text = lines[line + 1]
        if line_text then
          local from, to = clip_range(srow, scol, erow, ecol, line, #line_text)
          if from then paint(line + 1, from, to, hl, priority, conceal) end
        end
      end
      ::continue::
    end
  end)

  local out = {}
  for i, line in ipairs(lines) do
    local chunks = coalesce_line(line, hl_at[i], conceal_at[i])
    local visible = {}
    for _, ch in ipairs(chunks) do
      table.insert(visible, ch[1])
    end
    -- Drop lines that were only concealed markers (e.g. ``` fences), but keep
    -- intentional blank lines from the source.
    if table.concat(visible, "") == "" and line ~= "" then goto continue end
    table.insert(out, chunks)
    ::continue::
  end
  if #out == 0 then return { { { "", nil } } } end
  return out
end

return M
