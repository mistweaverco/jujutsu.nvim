local M = {}

---@param lines string[]
---@return string[]
function M.trim_blank(lines)
  return vim.tbl_filter(function(v) return v ~= "" end, lines)
end

---@param s string
---@return string
function M.remove_ansi(s) return (s:gsub("\27%[[0-9;]*[mK]", ""):gsub("\27%][^\7]*\7", "")) end

---@param lines string[]
---@return string[]
function M.remove_ansi_lines(lines) return vim.tbl_map(M.remove_ansi, lines) end

---@param list any[]
---@return table<any, boolean>
function M.reverse_lookup(list)
  local t = {}
  for _, v in ipairs(list or {}) do
    t[v] = true
  end
  return t
end

---@param tbl table
---@param item any
---@return boolean
function M.remove_item(tbl, item)
  for i, v in ipairs(tbl) do
    if v == item then
      table.remove(tbl, i)
      return true
    end
  end
  return false
end

---@param str string
---@return string
function M.trim(str) return (str:gsub("^%s+", ""):gsub("%s+$", "")) end

---@param path string
---@return string
function M.expand(path) return vim.fn.expand(path) end

---@param dir string
---@return string
function M.normalize_path(dir) return vim.fn.fnamemodify(dir, ":p"):gsub("/$", "") end

--- Human-readable label for a jj command (never the full argv string).
---@param cmd string[]
---@return string
function M.command_label(cmd)
  local i = 1
  while i <= #cmd do
    local p = cmd[i]
    if p == "--no-pager" or p == "--color=never" or p == "--ignore-working-copy" then
      i = i + 1
    elseif p == "jj" or p:match("/jj$") then
      i = i + 1
    else
      break
    end
  end

  local verb = cmd[i]
  local sub = cmd[i + 1]

  if verb == "git" and sub == "push" then return "Pushing…" end
  if verb == "git" and sub == "fetch" then return "Fetching…" end
  if verb == "bookmark" then
    local labels = {
      create = "Creating bookmark…",
      set = "Setting bookmark…",
      move = "Moving bookmark…",
      delete = "Deleting bookmark…",
      forget = "Forgetting bookmark…",
      track = "Tracking bookmark…",
      untrack = "Untracking bookmark…",
      rename = "Renaming bookmark…",
    }
    return labels[sub] or "Updating bookmark…"
  end
  if verb == "restore" then return "Restoring…" end
  if verb == "abandon" then return "Abandoning change…" end
  if verb == "describe" then return "Updating description…" end
  if verb == "new" then return "Creating change…" end
  if verb == "edit" then return "Editing change…" end
  if verb == "commit" then return "Committing…" end
  if verb == "squash" then return "Squashing…" end
  if verb == "rebase" then return "Rebasing…" end
  if verb == "split" then return "Splitting change…" end
  if verb == "workspace" then return "Updating workspace…" end
  if verb == "file" and sub == "untrack" then return "Untracking file…" end
  if verb == "git" and sub == "remote" then return "Updating remote…" end
  if verb == "diffedit" then return "Opening diffedit…" end

  return "Running…"
end

---Escape a path for a jj double-quoted string literal.
---@param path string
---@return string
local function escape_jj_string(path) return (tostring(path):gsub("\\", "\\\\"):gsub('"', '\\"')) end

---Convert a repo-relative path into a jj fileset that matches that exact file.
---Bare paths are filesets (`prefix-glob`); characters like `()[]*?` change meaning
---(e.g. SvelteKit `[uuid]` / `(group)` routes), so callers must quote them.
---@param path string
---@return string
function M.fileset_literal(path)
  path = tostring(path or "")
  if path == "" then return 'root-file:""' end
  -- Leave explicit fileset expressions alone (file:, glob:, root-file:, …).
  local prefix = path:match("^([%w_+-]+):")
  if
    prefix
    and (
      prefix == "file"
      or prefix == "cwd-file"
      or prefix == "glob"
      or prefix == "cwd-glob"
      or prefix == "prefix-glob"
      or prefix == "cwd-prefix-glob"
      or prefix == "root"
      or prefix == "root-file"
      or prefix == "root-glob"
      or prefix == "root-prefix-glob"
      or prefix == "cwd"
      or prefix:match("%-i$")
    )
  then
    return path
  end
  if path:sub(1, 1) == '"' or path:sub(1, 1) == "'" then return path end
  return string.format('root-file:"%s"', escape_jj_string(path))
end

---Make a path safe to embed in a `jujutsu://…` buffer name (`+`, `#`, `()`, …).
---@param path string
---@return string
function M.buf_name_path(path)
  path = tostring(path or "")
  -- Keep `/` so names stay readable; encode everything else that confuses
  -- Neovim buffer naming (`+cmd`, `#`, spaces, brackets, …).
  return (path:gsub("([^%w%-%._~/])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

return M
