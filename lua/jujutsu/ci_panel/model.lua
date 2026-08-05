local M = {}

---@param iso? string
---@return number|nil
function M.parse_time(iso)
  if not iso or iso == "" then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
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
    return "–", "JujutsuSubtle"
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
