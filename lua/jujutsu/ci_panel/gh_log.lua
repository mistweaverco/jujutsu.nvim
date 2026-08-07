local ansi = require("jujutsu.ansi")

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

---@class CiLogChunk
---@field name string
---@field lines string[]
---@field skipped? boolean

---@class CiLogNode
---@field kind "line"|"group"
---@field id? string
---@field title? string
---@field source? "step"|"group"|"section"
---@field skipped? boolean
---@field raw? string
---@field parsed? GhLogLine
---@field children? CiLogNode[]
---@field count integer

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
    if cmd == "endgroup" then return { skip = true, text = "", kind = "plain" } end
    if cmd == "group" then return { timestamp = timestamp, text = msg, kind = "group" } end
    if cmd == "section" then return { timestamp = timestamp, text = msg, kind = "section" } end
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

---@param title string
---@return string
local function clean_title(title)
  title = (title or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if title == "" then return "(untitled)" end
  return title
end

---@param name string
---@return string
local function clean_step_name(name)
  name = clean_title(name)
  if name == "UNKNOWN STEP" then return "Unknown step" end
  return name
end

---@param node CiLogNode
---@return integer
local function count_lines(node)
  if node.kind == "line" then return 1 end
  local n = 0
  for _, child in ipairs(node.children or {}) do
    n = n + count_lines(child)
  end
  node.count = n
  return n
end

---Parse a GitHub Actions / RFC3339 timestamp to epoch seconds (fractional).
---@param ts string|nil
---@return number|nil
local function parse_time(ts)
  if not ts or ts == "" then return nil end
  -- 2026-08-07T12:32:49.5734094Z or 2026-08-07T12:32:49Z
  local y, mo, d, h, mi, s, frac = ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)")
  if not y then return nil end
  frac = frac or ""
  if #frac > 6 then frac = frac:sub(1, 6) end
  local sub = tonumber("0." .. (frac ~= "" and frac or "0")) or 0
  local epoch = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  if not epoch then return nil end
  -- os.time is local; GHA stamps are UTC. Convert via difference if possible.
  -- For ordering within a single job this is consistent as long as all times use the same path.
  return epoch + sub
end

---@param line string
---@return number|nil
local function line_time(line)
  line = strip_bom(ansi.strip(line:gsub("\r$", "")))
  local ts = line:match("^(%d%d%d%d%-%d%d%-%d%dT[%d%.:%-+Z]+)")
  return parse_time(ts)
end

---@param line string
---@return boolean
local function is_post_cleanup_line(line) return line:find("Post job cleanup", 1, true) ~= nil end

---@param line string
---@return boolean
local function is_complete_job_line(line) return line:find("Cleaning up orphan processes", 1, true) ~= nil end

---@param name string
---@return boolean
local function is_post_or_complete(name) return name == "Complete job" or name:match("^Post ") ~= nil end

---Split a flat job log into per-step chunks using job step started_at / completed_at.
---Skipped steps are kept as empty placeholders. Same-second boundaries (common after
---failures) are resolved with post-cleanup markers so trailing failure output stays
---on the failed step.
---@param log_lines string[]
---@param steps { name?: string, number?: integer, conclusion?: string, started_at?: string, completed_at?: string }[]
---@return CiLogChunk[]|nil
function M.chunk_by_step_times(log_lines, steps)
  if not steps or #steps == 0 then return nil end

  ---@type { name: string, number: integer, conclusion?: string, skipped: boolean, start_e: number, completed_e: number, end_e: number, lines: string[] }[]
  local dated = {}
  for _, step in ipairs(steps) do
    local start_e = parse_time(step.started_at)
    local conclusion = step.conclusion
    local skipped = conclusion == "skipped"
    if start_e or skipped then
      local s = start_e or 0
      table.insert(dated, {
        name = step.name or "?",
        number = step.number or (#dated + 1),
        conclusion = conclusion,
        skipped = skipped,
        start_e = s,
        completed_e = parse_time(step.completed_at) or s,
        end_e = (parse_time(step.completed_at) or s) + 1,
        lines = {},
      })
    end
  end
  if #dated < 2 then return nil end

  table.sort(dated, function(a, b)
    if a.number ~= b.number then return a.number < b.number end
    return a.start_e < b.start_e
  end)

  -- Assignable steps: anything that actually ran (not skipped).
  local assignable = {}
  for _, step in ipairs(dated) do
    if not step.skipped then table.insert(assignable, step) end
  end
  if #assignable < 1 then return nil end

  for _, step in ipairs(assignable) do
    step.end_e = step.completed_e + 1
  end

  ---@param t number
  ---@param line string
  ---@return table
  local function step_for(t, line)
    local candidates = {}
    for _, step in ipairs(assignable) do
      if step.start_e <= t and t < step.end_e then table.insert(candidates, step) end
    end
    if #candidates == 0 then
      local best = assignable[1]
      for _, step in ipairs(assignable) do
        if step.start_e <= t then best = step end
      end
      return best
    end
    if #candidates == 1 then return candidates[1] end

    local postish = {}
    local mainish = {}
    for _, step in ipairs(candidates) do
      if is_post_or_complete(step.name) then
        table.insert(postish, step)
      else
        table.insert(mainish, step)
      end
    end

    -- Failure boundary: main step + post steps share the completion second.
    -- Keep lines on the main step until post-cleanup markers (handled by caller).
    if #mainish > 0 and #postish > 0 then
      if is_complete_job_line(line) then
        for _, step in ipairs(postish) do
          if step.name == "Complete job" then return step end
        end
      end
      if is_post_cleanup_line(line) then
        for _, step in ipairs(postish) do
          if step.name ~= "Complete job" then return step end
        end
        return postish[1]
      end
      local best = mainish[1]
      for i = 2, #mainish do
        local s = mainish[i]
        if s.start_e < best.start_e or (s.start_e == best.start_e and s.number < best.number) then best = s end
      end
      return best
    end

    -- Normal step handoff: prefer a later-started step; if they share a start
    -- second (common for short setup actions), prefer the tighter window.
    if #mainish > 0 then
      local best = mainish[1]
      for i = 2, #mainish do
        local s = mainish[i]
        if s.start_e > best.start_e then
          best = s
        elseif s.start_e == best.start_e then
          local best_span = best.end_e - best.start_e
          local span = s.end_e - s.start_e
          if span < best_span or (span == best_span and s.number < best.number) then best = s end
        end
      end
      return best
    end

    if is_complete_job_line(line) then
      for _, step in ipairs(postish) do
        if step.name == "Complete job" then return step end
      end
    end
    return postish[1] or candidates[1]
  end

  local post_cleanup_index = 0
  local post_steps = {}
  for _, step in ipairs(assignable) do
    if step.name:match("^Post ") then table.insert(post_steps, step) end
  end
  local complete_step = nil
  for _, step in ipairs(assignable) do
    if step.name == "Complete job" then
      complete_step = step
      break
    end
  end

  local last_t = assignable[1].start_e
  local current_post = nil
  local in_complete = false
  for _, line in ipairs(log_lines or {}) do
    local raw = strip_bom(line:gsub("\r$", ""))
    local stripped = ansi.strip(raw)
    if stripped:match("^── .+ ──$") then goto continue end
    local t = line_time(raw) or last_t
    last_t = t

    if is_complete_job_line(raw) then
      in_complete = true
      current_post = nil
      table.insert((complete_step or step_for(t, raw)).lines, raw)
      goto continue
    end
    if in_complete then
      table.insert((complete_step or step_for(t, raw)).lines, raw)
      goto continue
    end
    if is_post_cleanup_line(raw) and #post_steps > 0 then
      post_cleanup_index = math.min(post_cleanup_index + 1, #post_steps)
      current_post = post_steps[post_cleanup_index]
      table.insert(current_post.lines, raw)
      goto continue
    end
    if current_post then
      table.insert(current_post.lines, raw)
      goto continue
    end

    local step = step_for(t, raw)
    table.insert(step.lines, raw)
    ::continue::
  end

  local chunks = {}
  for _, step in ipairs(dated) do
    if step.skipped then
      table.insert(chunks, { name = step.name, lines = {}, skipped = true })
    elseif #step.lines > 0 then
      table.insert(chunks, { name = step.name, lines = step.lines })
    end
  end
  if #chunks < 2 then return nil end
  return chunks
end

---Split raw log lines into per-step chunks.
---Recognizes `── name ──` banners and `job\\tstep\\tcontent` prefixes from `gh run view --log`.
---@param log_lines string[]
---@param steps? { name?: string, number?: integer, started_at?: string, completed_at?: string }[]
---@return CiLogChunk[]
function M.chunk_by_steps(log_lines, steps)
  local chunks = {}
  ---@type CiLogChunk|nil
  local current = nil
  local saw_banner_or_tab = false

  local function ensure(name)
    name = clean_step_name(name or "Log")
    if current and current.name == name then return current end
    current = { name = name, lines = {} }
    table.insert(chunks, current)
    return current
  end

  local function add_line(line)
    if not current then ensure("Log") end
    table.insert(current.lines, line)
  end

  for _, line in ipairs(log_lines or {}) do
    local raw = strip_bom(line:gsub("\r$", ""))
    local stripped = ansi.strip(raw)

    local banner = stripped:match("^── (.+) ──$")
    if banner then
      saw_banner_or_tab = true
      ensure(banner)
      goto continue
    end

    local step, content = raw:match("^[^\t]+\t([^\t]*)\t(.*)$")
    if step then
      saw_banner_or_tab = true
      ensure(step)
      table.insert(current.lines, content)
      goto continue
    end

    add_line(raw)

    ::continue::
  end

  local function is_unlabeled(list)
    if #list == 0 then return true end
    if #list > 1 then
      for _, c in ipairs(list) do
        if c.name ~= "Unknown step" and c.name ~= "Log" then return false end
      end
      return true
    end
    local name = list[1].name
    return name == "Log" or name == "Unknown step"
  end

  -- Flat job logs (API plain text / gh UNKNOWN STEP): split using step timestamps.
  if (not saw_banner_or_tab or is_unlabeled(chunks)) and steps and #steps > 0 then
    local timed = M.chunk_by_step_times(log_lines, steps)
    if timed and #timed > 1 then return timed end
  end

  return chunks
end

---@param parent CiLogNode
---@param lines string[]
---@param next_id fun(): integer
local function append_parsed_lines(parent, lines, next_id)
  local stack = { parent }

  local function current() return stack[#stack] end

  local function open_group(title, source)
    local node = {
      kind = "group",
      id = "g" .. tostring(next_id()),
      title = clean_title(title),
      source = source,
      children = {},
      count = 0,
    }
    table.insert(current().children, node)
    table.insert(stack, node)
    return node
  end

  local function close_nested()
    local cur = current()
    if cur ~= parent and (cur.source == "group" or cur.source == "section") then table.remove(stack) end
  end

  local function close_open_section()
    local cur = current()
    if cur ~= parent and cur.source == "section" then table.remove(stack) end
  end

  for _, line in ipairs(lines or {}) do
    local stripped = ansi.strip(strip_bom(line:gsub("\r$", "")))
    -- Step banners are chunk boundaries only; never nest them as groups inside a step.
    if stripped:match("^── .+ ──$") then
      goto continue
    elseif M.looks_like_gh_actions(line) or M.looks_like_gh_actions(stripped) then
      local parsed = M.parse(line)
      if parsed.skip then
        close_nested()
      elseif parsed.kind == "group" then
        close_open_section()
        open_group(parsed.text, "group")
      elseif parsed.kind == "section" then
        close_open_section()
        open_group(parsed.text, "section")
      else
        table.insert(current().children, { kind = "line", raw = line, parsed = parsed, count = 1 })
      end
    else
      table.insert(current().children, { kind = "line", raw = line, count = 1 })
    end
    ::continue::
  end
end

---Build a foldable tree from raw CI log lines.
---Parent sections are job steps (`── name ──` / `gh` tab prefixes); `##[group]` nest inside them.
---@param log_lines string[]
---@param opts? { chunks?: CiLogChunk[], steps?: { name?: string }[] }
---@return CiLogNode[]
function M.build_tree(log_lines, opts)
  opts = opts or {}
  local next_id_val = 0
  local function next_id()
    next_id_val = next_id_val + 1
    return next_id_val
  end

  local chunks = opts.chunks
  if not chunks or #chunks == 0 then chunks = M.chunk_by_steps(log_lines or {}, opts.steps) end

  -- When zip/gh produced one chunk per job step, prefer the job API step names.
  if opts.steps and #opts.steps > 0 and #chunks == #opts.steps then
    for i, chunk in ipairs(chunks) do
      local step_name = opts.steps[i] and opts.steps[i].name
      if step_name and step_name ~= "" then chunk.name = step_name end
    end
  end

  local root_children = {}

  if #chunks == 0 then return root_children end

  -- No real step boundaries: keep ##[group] sections at the top level.
  if #chunks == 1 and (chunks[1].name == "Log" or chunks[1].name == "Unknown step") then
    local synthetic = {
      kind = "group",
      id = "root",
      title = "",
      children = {},
      count = 0,
    }
    append_parsed_lines(synthetic, chunks[1].lines, next_id)
    count_lines(synthetic)
    return synthetic.children
  end

  for _, chunk in ipairs(chunks) do
    local step_node = {
      kind = "group",
      id = "g" .. tostring(next_id()),
      title = clean_step_name(chunk.name),
      source = "step",
      skipped = chunk.skipped == true,
      children = {},
      count = 0,
    }
    if chunk.skipped then
      step_node.count = 0
    else
      append_parsed_lines(step_node, chunk.lines, next_id)
      count_lines(step_node)
    end
    table.insert(root_children, step_node)
  end

  return root_children
end

---@param nodes CiLogNode[]
---@param folded_default boolean
---@return table<string, boolean>
function M.default_folds(nodes, folded_default)
  local folds = {}
  local function walk(list)
    for _, node in ipairs(list or {}) do
      if node.kind == "group" and node.id then
        folds[node.id] = folded_default ~= false
        walk(node.children)
      end
    end
  end
  walk(nodes)
  return folds
end

---@param nodes CiLogNode[]
---@param id string
---@return CiLogNode|nil
function M.find_group(nodes, id)
  for _, node in ipairs(nodes or {}) do
    if node.kind == "group" then
      if node.id == id then return node end
      local found = M.find_group(node.children, id)
      if found then return found end
    end
  end
  return nil
end

---Return group id plus all descendant group ids.
---@param node CiLogNode
---@return string[]
function M.group_ids_recursive(node)
  local ids = {}
  local function walk(n)
    if not n or n.kind ~= "group" or not n.id then return end
    table.insert(ids, n.id)
    for _, child in ipairs(n.children or {}) do
      walk(child)
    end
  end
  walk(node)
  return ids
end

return M
