local model = require("jujutsu.ci_panel.model")

local M = {}

---@param lines string[]
---@param highlights table[]
---@param text string
---@param hl? string
---@param line_hl? string
local function push(lines, highlights, text, hl, line_hl)
  table.insert(lines, text)
  local row = #lines - 1
  if hl then
    table.insert(highlights, { line = row, col = 0, end_col = #text, hl = hl, line_hl = line_hl })
  elseif line_hl then
    table.insert(highlights, { line = row, line_hl = line_hl })
  end
end

---@param lines string[]
---@param highlights table[]
---@param text string
---@param col integer
---@param hl string
local function push_seg(lines, highlights, text, col, hl)
  local row = #lines - 1
  table.insert(highlights, { line = row, col = col, end_col = col + #text, hl = hl })
end

---@param run ForgeCiRun
---@return string
local function run_headline(run)
  local title = run.title or run.name or run.id
  local wf = run.workflow or ""
  if wf ~= "" and wf ~= title then return string.format("%s · %s", title, wf) end
  return title
end

---@param runs ForgeCiRun[]
---@param remote ForgeRemote
---@param opts? { has_more?: boolean, list_limit?: integer }
---@return string[], table[], { item_ranges: table[] }
function M.build_list(runs, remote, opts)
  opts = opts or {}
  local lines, highlights = {}, {}
  local item_ranges = {}
  push(lines, highlights, string.format("CI runs · %s/%s", remote.owner, remote.repo), "JujutsuPopupHeading")
  push(lines, highlights, "", nil)
  local header = string.format(
    "%s  %-42s  %-14s  %-12s  %-8s  %-8s  %s",
    model.pad("STATUS", 6),
    "TITLE",
    "WORKFLOW",
    "BRANCH",
    "EVENT",
    "ELAPSED",
    "AGE"
  )
  push(lines, highlights, header, "JujutsuSectionHeader")
  push(lines, highlights, string.rep("─", 100), "JujutsuSubtle")

  for _, run in ipairs(runs or {}) do
    local eff = model.effective_status(run.status, run.conclusion)
    local icon, icon_hl = model.status_icon(eff)
    local elapsed = run.elapsed or model.format_elapsed(run.started_at, run.updated_at)
    local age = model.format_age(run.created_at or run.started_at)
    local line = string.format(
      "%s  %-42s  %-14s  %-12s  %-8s  %-8s  %s",
      model.pad(icon, 6),
      model.truncate(run.title or run.name or "?", 42),
      model.truncate(run.workflow or "?", 14),
      model.truncate(run.branch or "?", 12),
      model.truncate(run.event or "?", 8),
      model.truncate(elapsed, 8),
      age
    )
    local start_line = #lines
    table.insert(lines, line)
    local row = #lines - 1
    table.insert(highlights, { line = row, col = 0, end_col = 6, hl = icon_hl })
    table.insert(item_ranges, { start_line = start_line, end_line = row, kind = "run", run = run })
  end

  if #(runs or {}) == 0 then push(lines, highlights, "(no CI runs)", "JujutsuSubtle") end
  if opts.has_more and opts.list_limit then
    push(lines, highlights, "", nil)
    local next_limit = opts.list_limit * 2
    local start_line = #lines
    push(lines, highlights, string.format("+ Load more… (%d → %d)", opts.list_limit, next_limit), "JujutsuHint")
    table.insert(item_ranges, { start_line = start_line, end_line = #lines - 1, kind = "load_more" })
  end
  push(lines, highlights, "", nil)
  local hints = "<cr> open run   o browser   r refresh   q close"
  if opts.has_more then hints = "+ load more   " .. hints end
  push(lines, highlights, hints, "JujutsuHint")
  return lines, highlights, { item_ranges = item_ranges }
end

---@param detail ForgeCiRunDetail
---@return string[], table[], { item_ranges: table[] }
function M.build_run(detail)
  local lines, highlights = {}, {}
  local item_ranges = {}
  local run = detail.run
  local eff = model.effective_status(run.status, run.conclusion)
  local icon, icon_hl = model.status_icon(eff)
  local headline = icon .. " " .. run_headline(run) .. " · " .. tostring(run.id)
  push(lines, highlights, headline, icon_hl)
  local trigger = "Triggered"
  if run.event and run.event ~= "" then trigger = trigger .. " via " .. run.event end
  local age = model.format_age(run.created_at or run.started_at)
  if age ~= "" then trigger = trigger .. " " .. age end
  push(lines, highlights, trigger, "JujutsuSubtle")
  push(lines, highlights, "", nil)
  push(lines, highlights, "JOBS", "JujutsuSectionHeader")

  for _, job in ipairs(detail.jobs or {}) do
    local j_eff = model.effective_status(job.status, job.conclusion)
    local j_icon, j_icon_hl = model.status_icon(j_eff)
    local elapsed = job.elapsed or model.format_elapsed(job.started_at, job.completed_at)
    local text =
      string.format("%s %s in %s (ID %s)", j_icon, job.name or "?", elapsed ~= "" and elapsed or "?", tostring(job.id))
    local start_line = #lines
    push(lines, highlights, text, j_icon_hl)
    local row = #lines - 1
    local id_str = tostring(job.id)
    local id_col = text:find(id_str, 1, true)
    if id_col then push_seg(lines, highlights, id_str, id_col - 1, "JujutsuCiId") end
    table.insert(item_ranges, { start_line = start_line, end_line = row, kind = "job", job = job, run = run })
  end
  if #(detail.jobs or {}) == 0 then push(lines, highlights, "(no jobs)", "JujutsuSubtle") end

  local annotations = detail.annotations or {}
  if #annotations > 0 then
    push(lines, highlights, "", nil)
    push(lines, highlights, "ANNOTATIONS", "JujutsuSectionHeader")
    for _, ann in ipairs(annotations) do
      local prefix = ann.level == "error" and "✗ " or "! "
      local hl = ann.level == "error" and "JujutsuCiFailure" or "JujutsuCiWarning"
      push(lines, highlights, prefix .. (ann.message or ""), hl)
      if ann.context and ann.context ~= "" then push(lines, highlights, ann.context, "JujutsuSubtle") end
    end
  end

  push(lines, highlights, "", nil)
  if run.url and run.url ~= "" then push(lines, highlights, "View this run: " .. run.url, "JujutsuSubtle") end
  push(lines, highlights, "", nil)
  push(
    lines,
    highlights,
    "<cr> open job   l logs   o browser   x cancel   r refresh   <bs> back   q close",
    "JujutsuHint"
  )
  return lines, highlights, { item_ranges = item_ranges }
end

---@param detail ForgeCiJobDetail
---@param caps table
---@return string[], table[], { item_ranges: table[] }
function M.build_job(detail, caps)
  local lines, highlights = {}, {}
  local item_ranges = {}
  local run = detail.run
  local job = detail.job
  local run_eff = model.effective_status(run.status, run.conclusion)
  local run_icon = select(1, model.status_icon(run_eff))
  push(lines, highlights, run_icon .. " " .. run_headline(run) .. " · " .. tostring(run.id), "JujutsuSubtle")
  local age = model.format_age(run.created_at or run.started_at)
  if age ~= "" then push(lines, highlights, "Triggered " .. age, "JujutsuSubtle") end
  push(lines, highlights, "", nil)

  local j_eff = model.effective_status(job.status, job.conclusion)
  local j_icon, j_icon_hl = model.status_icon(j_eff)
  local elapsed = job.elapsed or model.format_elapsed(job.started_at, job.completed_at)
  local header =
    string.format("%s %s in %s (ID %s)", j_icon, job.name or "?", elapsed ~= "" and elapsed or "?", tostring(job.id))
  push(lines, highlights, header, j_icon_hl)
  push(lines, highlights, "", nil)

  local steps = job.steps or {}
  if #steps > 0 then
    for _, step in ipairs(steps) do
      local s_eff = model.effective_status(step.status, step.conclusion)
      local s_icon, s_icon_hl = model.status_icon(s_eff)
      push(lines, highlights, s_icon .. " " .. (step.name or "?"), s_icon_hl)
    end
  else
    push(lines, highlights, "(no steps)", "JujutsuSubtle")
  end

  local annotations = detail.annotations or {}
  if #annotations > 0 then
    push(lines, highlights, "", nil)
    push(lines, highlights, "ANNOTATIONS", "JujutsuSectionHeader")
    for _, ann in ipairs(annotations) do
      push(lines, highlights, "! " .. (ann.message or ""), "JujutsuCiWarning")
      if ann.context and ann.context ~= "" then push(lines, highlights, ann.context, "JujutsuSubtle") end
    end
  end

  push(lines, highlights, "", nil)
  if caps and caps.ci and caps.ci.logs then push(lines, highlights, "Press l to view full job log", "JujutsuHint") end
  if run.url and run.url ~= "" then push(lines, highlights, "View this run: " .. run.url, "JujutsuSubtle") end
  push(lines, highlights, "", nil)
  local hints = "o browser"
  if caps and caps.ci and caps.ci.logs then hints = "l logs   " .. hints end
  push(lines, highlights, hints .. "   r refresh   <bs> back   q close", "JujutsuHint")
  return lines, highlights, { item_ranges = item_ranges }
end

---@param job ForgeCiJob
---@param log_lines string[]
---@return string[], table[]
function M.build_logs(job, log_lines)
  local lines, highlights = {}, {}
  push(lines, highlights, string.format("Log · ID %s", tostring(job.id)), "JujutsuPopupHeading")
  push(lines, highlights, "", nil)
  for _, line in ipairs(log_lines or {}) do
    if line:match("^── .+ ──$") then
      push(lines, highlights, line, "JujutsuSectionHeader")
    else
      table.insert(lines, line)
    end
  end
  if #(log_lines or {}) == 0 then push(lines, highlights, "(empty log)", "JujutsuSubtle") end
  push(lines, highlights, "", nil)
  push(lines, highlights, "<bs> back   q close", "JujutsuHint")
  return lines, highlights
end

---@param message string
---@return string[], table[]
function M.build_loading(message)
  return { message or "Loading…" }, { { line = 0, col = 0, end_col = #(message or ""), hl = "JujutsuSubtle" } }
end

---@param message string
---@return string[], table[]
function M.build_error(message)
  local lines, highlights = {}, {}
  push(lines, highlights, "Error", "JujutsuConflict")
  for _, line in ipairs(vim.split(tostring(message or ""), "\n", { plain = true })) do
    push(lines, highlights, line, "JujutsuSubtle")
  end
  push(lines, highlights, "", nil)
  push(lines, highlights, "r refresh   q close", "JujutsuHint")
  return lines, highlights
end

return M
