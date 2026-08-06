local M = {}

---GitHub Actions log timestamp prefix.
local TS = "^(%d%d%d%d%-%d%d%-%d%dT[%d%.:%-+Z]+)%s*(.*)$"

---@param line string
---@return string
local function strip_bom(line)
  if line:sub(1, 3) == "\239\187\191" then return line:sub(4) end
  return line
end

---@class GhLogLine
---@field skip? boolean
---@field timestamp? string
---@field text string
---@field kind "plain"|"group"|"warning"|"error"|"notice"|"debug"|"section"|"command"

---@param line string
---@return GhLogLine
function M.parse(line)
  line = strip_bom(line)
  line = line:gsub("\r$", "")

  local timestamp, rest = line:match(TS)
  if not timestamp then
    rest = line
  else
    rest = rest or ""
  end

  local cmd, msg = rest:match("^##%[([%w]+)%](.*)$")
  if cmd then
    msg = msg or ""
    if cmd == "endgroup" then return { skip = true, text = "" } end
    if cmd == "group" or cmd == "section" then return { timestamp = timestamp, text = msg, kind = "group" } end
    if cmd == "warning" then return { timestamp = timestamp, text = msg, kind = "warning" } end
    if cmd == "error" then return { timestamp = timestamp, text = msg, kind = "error" } end
    if cmd == "notice" then return { timestamp = timestamp, text = msg, kind = "notice" } end
    if cmd == "debug" then return { timestamp = timestamp, text = msg, kind = "debug" } end
    return { timestamp = timestamp, text = msg, kind = "plain" }
  end

  local command_body = rest:match("^%[command%](.*)$")
  if command_body then return { timestamp = timestamp, text = command_body, kind = "command" } end

  return { timestamp = timestamp, text = rest, kind = "plain" }
end

---@param line string
---@return boolean
function M.looks_like_gh_actions(line)
  line = strip_bom(line)
  if line:match("^%d%d%d%d%-%d%d%-%d%dT[%d%.:%-+Z]+") then return true end
  if line:match("##%[[%w]+%]") then return true end
  if line:match("%^%[") then return true end
  return false
end

return M
