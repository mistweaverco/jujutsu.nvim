local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

-- Build a jj template that emits fields separated by unit separator + record separator
local function field_template(fields)
  local parts = {}
  for i, f in ipairs(fields) do
    if i > 1 then
      table.insert(parts, string.format('"\\x1f" ++ %s', f))
    else
      table.insert(parts, f)
    end
  end
  return table.concat(parts, " ++ ") .. ' ++ "\\x1e"'
end

local WC_TEMPLATE = field_template({
  "change_id.short(8)",
  "commit_id.short(8)",
  'bookmarks.join(",")',
  "description.first_line()",
  'if(conflict, "true", "false")',
  'if(empty, "true", "false")',
})

local LOG_TEMPLATE = field_template({
  "change_id.short(8)",
  "commit_id.short(8)",
  'bookmarks.join(",")',
  "description.first_line()",
  'if(conflict, "true", "false")',
  "author.timestamp().ago()",
})

local REAL_SEP = "\x1f"
local REAL_REC = "\x1e"

---@class ChangeInfo
---@field change_id string
---@field commit_id string
---@field bookmarks string[]
---@field description string
---@field conflict boolean
---@field empty? boolean
---@field ago? string

---@class FileStatus
---@field path string
---@field status string
---@field diff? string[]

---@class StatusData
---@field working_copy ChangeInfo|nil
---@field parent ChangeInfo|nil
---@field files FileStatus[]
---@field conflicts string[]
---@field recent ChangeInfo[]
---@field bookmarks { name: string, remote: string, change_id: string, commit_id: string, description: string, target: string, conflict: boolean, deleted: boolean }[]
---@field root string

---@param line string
---@return string[]
local function split_fields(line) return vim.split(line, REAL_SEP, { plain = true }) end

---@param text string
---@return ChangeInfo[]
local function parse_records(text)
  local records = {}
  for rec in (text .. REAL_REC):gmatch("(.-)" .. REAL_REC) do
    if rec ~= "" then
      local fields = split_fields(rec:gsub("\n", ""))
      if fields[1] and fields[1] ~= "" then
        local bookmarks = {}
        if fields[3] and fields[3] ~= "" then bookmarks = vim.split(fields[3], ",", { plain = true }) end
        table.insert(records, {
          change_id = fields[1] or "",
          commit_id = fields[2] or "",
          bookmarks = bookmarks,
          description = fields[4] or "",
          conflict = fields[5] == "true",
          empty = fields[6] == "true",
          ago = fields[6],
        })
      end
    end
  end
  return records
end

---@param summary_lines string[]
---@return FileStatus[], string[]
local function parse_diff_summary(summary_lines)
  local files = {}
  local conflicts = {}
  for _, line in ipairs(summary_lines) do
    local status, path = line:match("^([MADRC?])%s+(.+)$")
    if not status then
      status, path = line:match("^(%S+)%s+(.+)$")
    end
    if status and path then
      if status == "C" or line:lower():find("conflict") then table.insert(conflicts, path) end
      table.insert(files, { path = path, status = status:sub(1, 1) })
    end
  end
  return files, conflicts
end

---@param root string
---@return StatusData
function M.fetch(root)
  local opts = { cwd = root, hidden = true, trim = false }

  local wc_res = cli.log.revisions("@").no_graph.template(WC_TEMPLATE).limit(1).call(opts)
  local parent_res = cli.log.revisions("@-").no_graph.template(WC_TEMPLATE).limit(1).call(opts)

  local recent_count = config.values.status.recent_commit_count or 10
  local recent_res = cli.log.revisions("ancestors(@-)").no_graph.template(LOG_TEMPLATE).limit(recent_count).call(opts)

  local diff_res = cli.diff.summary.call(opts)
  local bookmarks = require("jujutsu.jj.bookmark").list(root)

  local working_copy = parse_records(table.concat(wc_res.stdout, "\n"))[1]
  local parent = parse_records(table.concat(parent_res.stdout, "\n"))[1]
  local recent = parse_records(table.concat(recent_res.stdout, "\n"))

  local files, conflicts_from_diff = parse_diff_summary(diff_res.stdout)

  local resolve_res = cli.resolve.list.call(vim.tbl_extend("force", opts, {
    on_error = function() return false end,
  }))
  local conflicts = {}
  for _, line in ipairs(resolve_res.stdout) do
    local p = line:match("^%S+%s+(.+)$") or line
    if p and p ~= "" then table.insert(conflicts, p) end
  end
  if #conflicts == 0 then conflicts = conflicts_from_diff end

  pcall(function() bookmarks = require("jujutsu.forge").annotate_bookmarks(bookmarks, root) end)

  return {
    working_copy = working_copy,
    parent = parent,
    files = files,
    conflicts = conflicts,
    recent = recent,
    bookmarks = bookmarks,
    root = root,
  }
end

---@param root string
---@param path string
---@return string[]
function M.file_diff(root, path)
  -- Prefer git-format so lines start with +/-/@@ (needed for coloring)
  local res = cli.diff.git.paths(path).call({ cwd = root, hidden = true, remove_ansi = true })
  if res.code ~= 0 or #res.stdout == 0 then
    res = cli.diff.paths(path).call({ cwd = root, hidden = true, remove_ansi = true })
  end
  return res.stdout
end

return M
