local M = {}

---@class DiffHunk
---@field header string
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field lines string[] body lines (+/- / context), excluding @@ header
---@field diff_from integer 1-based index of @@ in raw diff lines
---@field diff_to integer 1-based inclusive end index in raw diff lines

---Parse unified/git diff lines into hunks.
---@param diff_lines string[]
---@return DiffHunk[]
function M.parse_hunks(diff_lines)
  local hunks = {}
  ---@type DiffHunk|nil
  local hunk = nil

  local function flush()
    if hunk then
      hunks[#hunks + 1] = hunk
      hunk = nil
    end
  end

  for i, line in ipairs(diff_lines or {}) do
    local old_s, old_c, new_s, new_c = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if not old_s then
      old_s, old_c, new_s, new_c = line:match("^@@@+ %-(%d+),?(%d*) .- %+(%d+),?(%d*) @@@+")
    end
    if old_s then
      flush()
      hunk = {
        header = line,
        old_start = tonumber(old_s) or 0,
        old_count = (old_c ~= "" and tonumber(old_c)) or 1,
        new_start = tonumber(new_s) or 0,
        new_count = (new_c ~= "" and tonumber(new_c)) or 1,
        lines = {},
        diff_from = i,
        diff_to = i,
      }
    elseif hunk then
      if
        not line:match("^diff ")
        and not line:match("^index ")
        and not line:match("^%-%-%-")
        and not line:match("^%+%+%+")
      then
        hunk.lines[#hunk.lines + 1] = line
        hunk.diff_to = i
      end
    end
  end
  flush()
  return hunks
end

---Find 0-based hunk index containing a 1-based raw diff line index.
---@param hunks DiffHunk[]
---@param diff_index integer
---@return integer|nil
function M.hunk_index_at(hunks, diff_index)
  for i, h in ipairs(hunks) do
    if diff_index >= h.diff_from and diff_index <= h.diff_to then return i - 1 end
  end
  return nil
end

---Apply selected hunks onto parent (left/base) file lines.
---@param base_lines string[]
---@param hunks DiffHunk[]
---@return string[]
function M.apply_hunks(base_lines, hunks)
  if not hunks or #hunks == 0 then
    local copy = {}
    for i, l in ipairs(base_lines) do
      copy[i] = l
    end
    return copy
  end

  local sorted = {}
  for i, h in ipairs(hunks) do
    sorted[i] = h
  end
  table.sort(sorted, function(a, b) return a.old_start < b.old_start end)

  local result = {}
  local src = 1
  for _, hunk in ipairs(sorted) do
    local start = hunk.old_start
    -- New-file hunks use old_start 0
    if start == 0 then start = 1 end
    while src < start and src <= #base_lines do
      result[#result + 1] = base_lines[src]
      src = src + 1
    end
    for _, line in ipairs(hunk.lines) do
      local prefix = line:sub(1, 1)
      if prefix == "+" or prefix == " " then
        result[#result + 1] = line:sub(2)
      elseif prefix == "\\" then
        -- "\ No newline at end of file" - ignore for content
      elseif prefix == "-" then
        -- removed from base; skip
      end
    end
    if hunk.old_count > 0 and hunk.old_start > 0 then src = hunk.old_start + hunk.old_count end
  end
  while src <= #base_lines do
    result[#result + 1] = base_lines[src]
    src = src + 1
  end
  return result
end

return M
