local config = require("jujutsu.config")

local M = {}

local ABSOLUTE_PATTERN = "%Y-%m-%d %H:%M:%S"

---@param pattern string
---@return string
local function escape_format(pattern) return (pattern:gsub("\\", "\\\\"):gsub('"', '\\"')) end

---Resolve configured date mode into a concrete style.
---@param kind? "commit"|"log"
---@return "relative"|string  -- "relative" or strftime pattern
local function resolved_format(kind)
  local key = kind == "log" and "log_date_format" or "commit_date_format"
  local fmt = config.values[key]
  if fmt == nil or fmt == "" or fmt == "absolute" then return ABSOLUTE_PATTERN end
  return fmt
end

---jj template expression for a timestamp field.
---@param source? "author"|"committer"
---@param kind? "commit"|"log" which config key to use
---@return string
function M.timestamp_expr(source, kind)
  source = source or "author"
  local fmt = resolved_format(kind)
  local base = source .. ".timestamp()"
  if fmt == "relative" then return base .. ".ago()" end
  return string.format('%s.local().format("%s")', base, escape_format(fmt))
end

return M
