local model = require("jujutsu.issue_panel.model")
local util = require("jujutsu.util")

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

---Push a markdown body. When `markdown` is true, leave lines unhighlighted so
---treesitter / markdown render plugins own the body; structural chrome (headers)
---keeps JujutsuIssue* extmarks. When false, apply lightweight line heuristics.
---@param lines string[]
---@param highlights table[]
---@param body any
---@param opts? { markdown?: boolean }
local function push_body(lines, highlights, body, opts)
  opts = opts or {}
  local as_markdown = opts.markdown ~= false
  body = model.as_string(body)
  if body == "" or vim.trim(body) == "" then
    push(lines, highlights, "(no description)", "JujutsuSubtle")
    return
  end
  if as_markdown then
    for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
      -- No extmark HL: treesitter markdown (and optional render plugins) highlight.
      table.insert(lines, line)
    end
    return
  end
  local in_fence = false
  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    local hl = "JujutsuIssueBody"
    if line:match("^```") then
      in_fence = not in_fence
      hl = "JujutsuIssueCode"
    elseif in_fence then
      hl = "JujutsuIssueCode"
    elseif line:match("^#%s") or line:match("^##") then
      hl = "JujutsuIssueHeading"
    elseif line:match("^%s*[-*]%s") or line:match("^%s*%d+%.%s") then
      hl = "JujutsuIssueList"
    end
    push(lines, highlights, line, hl)
  end
end

---@param data { topic?: ForgeTopic, comments?: ForgeConversationComment[], error?: string, loading?: boolean }
---@param opts? { markdown?: boolean }
---@return string[], table[], { comment_ranges: table[] }|nil
function M.build(data, opts)
  opts = opts or {}
  local markdown = opts.markdown ~= false
  local lines, highlights = {}, {}
  local comment_ranges = {}
  if data.loading then
    push(lines, highlights, "Loading…", "JujutsuSubtle")
    return lines, highlights, { comment_ranges = comment_ranges }
  end
  if data.error then
    push(lines, highlights, "Error", "JujutsuConflict")
    push(lines, highlights, "", nil)
    for _, line in ipairs(vim.split(util.normalize_newlines(tostring(data.error)), "\n", { plain = true })) do
      push(lines, highlights, line, "JujutsuSubtle")
    end
    return lines, highlights, { comment_ranges = comment_ranges }
  end

  local topic = data.topic
  if not topic then
    push(lines, highlights, "No issue/PR selected", "JujutsuSubtle")
    return lines, highlights, { comment_ranges = comment_ranges }
  end

  local kind_label = topic.kind == "pr" and "Pull request" or "Issue"
  push(lines, highlights, topic.repo or "", "JujutsuSubtle")
  push(lines, highlights, string.format("%s #%s", kind_label, tostring(topic.number)), "JujutsuPopupHeading")
  push(lines, highlights, topic.title or "", "JujutsuIssueTitle")

  local state = model.state_label(topic.state)
  local state_hl = "JujutsuIssueStateOpen"
  if state == "closed" or state == "declined" then
    state_hl = "JujutsuIssueStateClosed"
  elseif state == "merged" then
    state_hl = "JujutsuIssueStateMerged"
  elseif state == "draft" then
    state_hl = "JujutsuIssueStateDraft"
  end
  push(lines, highlights, string.format("[%s]", state), state_hl)

  local meta = string.format("by %s", topic.author or "unknown")
  local created = model.format_time(topic.created_at)
  local updated = model.format_time(topic.updated_at)
  if created ~= "" then meta = meta .. " · created " .. created end
  if updated ~= "" and updated ~= created then meta = meta .. " · updated " .. updated end
  push(lines, highlights, meta, "JujutsuSubtle")

  if topic.labels and #topic.labels > 0 then
    local labels_mod = require("jujutsu.forge.labels")
    local prefix = "labels: "
    local line = prefix
    local segs = {}
    for i, lab in ipairs(topic.labels) do
      local name = labels_mod.display(lab)
      if i > 1 then line = line .. " " end
      local start_col = #line
      line = line .. name
      table.insert(segs, {
        col = start_col,
        end_col = #line,
        hl = labels_mod.hl_group(lab),
      })
    end
    table.insert(lines, line)
    local row = #lines - 1
    for _, seg in ipairs(segs) do
      table.insert(highlights, { line = row, col = seg.col, end_col = seg.end_col, hl = seg.hl })
    end
  end
  if topic.assignees and #topic.assignees > 0 then
    push(lines, highlights, "assignees: " .. table.concat(topic.assignees, ", "), "JujutsuSubtle")
  end

  push(lines, highlights, string.rep("─", 40), "JujutsuSubtle")
  push(lines, highlights, "Description", "JujutsuSectionHeader")
  push(lines, highlights, "", nil)
  push_body(lines, highlights, topic.body or "", { markdown = markdown })

  push(lines, highlights, "", nil)
  push(lines, highlights, string.rep("─", 40), "JujutsuSubtle")
  local comments = data.comments or {}
  push(lines, highlights, string.format("Conversation (%d)", #comments), "JujutsuSectionHeader")
  push(lines, highlights, "", nil)

  if #comments == 0 then
    push(lines, highlights, "(no comments yet)", "JujutsuSubtle")
  else
    for i, c in ipairs(comments) do
      if i > 1 then push(lines, highlights, "", nil) end
      local start_line = #lines
      local assoc = c.author_association and c.author_association ~= "NONE" and (" · " .. c.author_association) or ""
      local kind = c.kind == "review" and " [review]" or ""
      local head = string.format("%s%s%s · %s", c.author or "unknown", assoc, kind, model.format_time(c.created_at))
      push(lines, highlights, head, "JujutsuIssueCommentAuthor")
      push(lines, highlights, string.rep("·", 32), "JujutsuSubtle")
      push_body(lines, highlights, c.body or "", { markdown = markdown })
      table.insert(comment_ranges, {
        start_line = start_line,
        end_line = #lines - 1,
        comment = c,
      })
    end
  end

  push(lines, highlights, "", nil)
  push(
    lines,
    highlights,
    "c comment  e edit comment  x delete  l labels  E edit title/body  C close  r refresh  o browser  q close",
    "JujutsuHint"
  )
  return lines, highlights, { comment_ranges = comment_ranges }
end

return M
