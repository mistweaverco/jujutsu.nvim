local M = {}

---Unix epoch for a UTC civil datetime (Howard Hinnant days_from_civil).
---os.time(table) is local wall-clock, so it cannot parse forge ISO stamps (UTC).
---@param y integer
---@param m integer
---@param d integer
---@param h integer
---@param mi integer
---@param s integer
---@return integer
local function utc_epoch(y, m, d, h, mi, s)
  local y0 = y - (m <= 2 and 1 or 0)
  local era = math.floor(y0 / 400)
  local yoe = y0 - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + h * 3600 + mi * 60 + s
end

---Parse an ISO-8601 / RFC3339 timestamp to unix epoch seconds.
---Forge APIs (GitHub, GitLab, Forgejo, Bitbucket) send UTC (`Z` / `+00:00`).
---@param iso? string
---@return number|nil
function M.parse_time(iso)
  if not iso or iso == "" then return nil end
  -- Lua patterns cannot make a capture optional with `?`; split fraction / tz off the tail.
  local y, mo, d, h, mi, s, rest = iso:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)(.*)$")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
  if not (y and mo and d and h and mi and s) then return nil end

  rest = rest or ""
  local frac = rest:match("^(%.%d+)")
  if frac then rest = rest:sub(#frac + 1) end

  local off = 0
  local tz = vim.trim(rest)
  if tz ~= "" and tz ~= "Z" and tz ~= "z" then
    local sign, th, tm = tz:match("^([%+%-])(%d%d):?(%d%d)$")
    if sign then
      off = tonumber(th) * 3600 + tonumber(tm) * 60
      if sign == "-" then off = -off end
    end
  end

  local sub = 0
  if frac then sub = tonumber("0" .. frac) or 0 end
  return utc_epoch(y, mo, d, h, mi, s) - off + sub
end

---@param start_iso? string
---@param end_iso? string
---@return string
function M.format_elapsed(start_iso, end_iso)
  local start_t = M.parse_time(start_iso)
  if not start_t then return "" end
  local end_t = M.parse_time(end_iso) or os.time()
  local secs = math.max(0, end_t - start_t)
  if secs < 60 then return string.format("%ds", secs) end
  local mins = math.floor(secs / 60)
  local rem = secs % 60
  if mins < 60 then return string.format("%dm%ds", mins, rem) end
  local hrs = math.floor(mins / 60)
  mins = mins % 60
  return string.format("%dh%dm", hrs, mins)
end

---@param elapsed? string
---@param start_iso? string
---@param end_iso? string
---@return string
function M.elapsed_text(elapsed, start_iso, end_iso)
  if elapsed and elapsed ~= "" then return elapsed end
  return M.format_elapsed(start_iso, end_iso)
end

---@param iso? string
---@return string
function M.format_age(iso)
  local t = M.parse_time(iso)
  if not t then return "" end
  local secs = math.max(0, os.time() - t)
  if secs < 60 then return "just now" end
  local mins = math.floor(secs / 60)
  if mins < 60 then return string.format("about %d minute%s ago", mins, mins == 1 and "" or "s") end
  local hrs = math.floor(mins / 60)
  if hrs < 48 then return string.format("about %d hour%s ago", hrs, hrs == 1 and "" or "s") end
  local days = math.floor(hrs / 24)
  if days < 60 then return string.format("about %d day%s ago", days, days == 1 and "" or "s") end
  local months = math.floor(days / 30)
  return string.format("about %d month%s ago", months, months == 1 and "" or "s")
end

---@param status? string
---@param conclusion? string
---@return string
function M.effective_status(status, conclusion)
  status = string.lower(status or "")
  conclusion = string.lower(conclusion or "")
  if status == "completed" and conclusion ~= "" then return conclusion end
  if conclusion ~= "" then return conclusion end
  return status
end

---@param status string
---@return string icon, string hl
function M.status_icon(status)
  status = string.lower(status or "")
  if status == "success" or status == "successful" or status == "completed" or status == "passed" then
    return "✓", "JujutsuCiSuccess"
  end
  if status == "failure" or status == "failed" or status == "error" or status == "timed_out" or status == "expired" then
    return "✗", "JujutsuCiFailure"
  end
  if
    status == "cancelled"
    or status == "canceled"
    or status == "skipped"
    or status == "neutral"
    or status == "stopped"
    or status == "halted"
    or status == "not_run"
  then
    return "-", "JujutsuSubtle"
  end
  if
    status == "in_progress"
    or status == "running"
    or status == "queued"
    or status == "pending"
    or status == "waiting"
    or status == "created"
    or status == "waiting_for_resource"
    or status == "paused"
  then
    return "●", "JujutsuCiPending"
  end
  return "?", "JujutsuSubtle"
end

---@param text string
---@param width integer
---@return string
function M.truncate(text, width)
  text = text or ""
  if #text <= width then return text end
  if width <= 3 then return text:sub(1, width) end
  return text:sub(1, width - 1) .. "…"
end

---@param text string
---@param width integer
---@return string
function M.pad(text, width)
  text = text or ""
  if #text >= width then return text:sub(1, width) end
  return text .. string.rep(" ", width - #text)
end

return M
