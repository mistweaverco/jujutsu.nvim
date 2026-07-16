local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

local SEP, REC = "\x1f", "\x1e"

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

local META_TEMPLATE = field_template({
  "change_id.short(8)",
  "author.email()",
  "committer.timestamp()",
  'local_bookmarks.map(|b| b.name()).join(",")',
  'local_tags.map(|t| t.name()).join(",")',
  "commit_id.short(8)",
  'if(signature, signature.status(), "")',
  "description.first_line()",
  "change_id.shortest(4)",
})

---@param ts string
---@return string
local function format_timestamp(ts) return (ts or ""):match("^(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)") or ts or "" end

---@param status string
---@return string, string
local function signature_mark(status)
  if status == "good" then return "✓︎", "JujutsuStatSigGood" end
  if status == "bad" then return "✗", "JujutsuStatSigBad" end
  return "?", "JujutsuStatSigUnknown"
end

---@param change_id string
---@param shortest? string
---@return string, string
local function split_change_id(change_id, shortest)
  local short = change_id:sub(1, 8)
  local prefix_len = shortest and math.min(#shortest, #short) or math.min(4, #short)
  if prefix_len < 1 then prefix_len = 1 end
  return short:sub(1, prefix_len), short:sub(prefix_len + 1)
end

---@param root string
---@param rev string
---@return table
local function fetch_meta(root, rev)
  local res = cli.log.revisions(rev).no_graph.template(META_TEMPLATE).limit(1).call({
    cwd = root,
    hidden = true,
    trim = false,
  })
  local info = {
    change_id = rev,
    email = "",
    timestamp = "",
    bookmarks = {},
    tags = {},
    commit_id = "",
    signature = "",
    description = "(no description set)",
    shortest = "",
  }
  local text = table.concat(res.stdout, "\n")
  for rec in (text .. REC):gmatch("(.-)" .. REC) do
    if rec ~= "" then
      local f = vim.split(rec:gsub("\n", ""), SEP, { plain = true })
      if f[1] and f[1] ~= "" then
        info.change_id = f[1]
        info.email = f[2] or ""
        info.timestamp = format_timestamp(f[3] or "")
        if f[4] and f[4] ~= "" then info.bookmarks = vim.split(f[4], ",", { plain = true }) end
        if f[5] and f[5] ~= "" then info.tags = vim.split(f[5], ",", { plain = true }) end
        info.commit_id = f[6] or ""
        info.signature = f[7] or ""
        info.description = (f[8] and f[8] ~= "") and f[8] or "(no description set)"
        info.shortest = f[9] or ""
        break
      end
    end
  end
  return info
end

---@param root string
---@param rev string
---@return string[]
local function fetch_stat(root, rev)
  local res = cli.diff.revision(rev).stat.call({ cwd = root, hidden = true, remove_ansi = true })
  if res.code ~= 0 then return {} end
  return res.stdout or {}
end

---@param line string
---@return integer|nil, integer|nil, integer|nil
local function parse_summary(line)
  local files, ins, dels = line:match("^(%d+) files? changed, (%d+) insertions?%(%+%), (%d+) deletions?%(%-%)$")
  if files then return tonumber(files), tonumber(ins), tonumber(dels) end
  files, ins = line:match("^(%d+) files? changed, (%d+) insertions?%(%+%)$")
  if files then return tonumber(files), tonumber(ins), 0 end
  files, dels = line:match("^(%d+) files? changed, (%d+) deletions?%(%-%)$")
  if files then return tonumber(files), 0, tonumber(dels) end
  files = line:match("^(%d+) files? changed$")
  if files then return tonumber(files), 0, 0 end
  return nil
end

---@param info table
---@param stat_lines string[]
---@return string[], table[]
local function build_render(info, stat_lines)
  local lines = {}
  local highlights = {}

  local function add(text, parts)
    table.insert(lines, text)
    local row = #lines - 1
    for _, p in ipairs(parts or {}) do
      if p.end_col > p.col then
        table.insert(highlights, {
          line = row,
          col = p.col,
          end_col = p.end_col,
          hl = p.hl,
        })
      end
    end
  end

  -- Header: ◆  <change> <email> <ts> <bookmarks...> <commit> [sig]
  do
    local chunks = {}
    local hls = {}
    local col = 0
    local function push(str, hl)
      table.insert(chunks, str)
      if hl and #str > 0 then table.insert(hls, { col = col, end_col = col + #str, hl = hl }) end
      col = col + #str
    end

    push("◆  ", "JujutsuStatGraph")
    local prefix, rest = split_change_id(info.change_id, info.shortest)
    push(prefix, "JujutsuChangeIdPrefix")
    if rest ~= "" then push(rest, "JujutsuChangeIdRest") end
    push(" ", nil)
    push(info.email, "JujutsuDescription")
    push(" ", nil)
    push(info.timestamp, "JujutsuSubtle")
    for _, bm in ipairs(info.bookmarks) do
      push(" ", nil)
      push(bm, "JujutsuBranch")
    end
    for _, tag in ipairs(info.tags) do
      push(" ", nil)
      push(tag, "JujutsuTag")
    end
    push(" ", nil)
    push(info.commit_id, "JujutsuCommitId")
    local mark, mark_hl = signature_mark(info.signature)
    push(" [", "JujutsuSubtle")
    push(mark, mark_hl)
    push("]", "JujutsuSubtle")
    add(table.concat(chunks), hls)
  end

  -- Description: │  <desc>
  do
    local desc = info.description
    local desc_hl = desc == "(no description set)" and "JujutsuSubtle" or "Normal"
    add("│  " .. desc, {
      { col = 0, end_col = 1, hl = "JujutsuStatGraph" },
      { col = 3, end_col = 3 + #desc, hl = desc_hl },
    })
  end

  if #stat_lines == 0 then
    add("~  (no changes)", {
      { col = 0, end_col = 1, hl = "JujutsuStatGraph" },
      { col = 3, end_col = 16, hl = "JujutsuSubtle" },
    })
    return lines, highlights
  end

  for i, raw in ipairs(stat_lines) do
    local lead = (i == 1) and "~  " or "   "
    local lead_hl = (i == 1) and "JujutsuStatGraph" or nil
    local files, ins, dels = parse_summary(raw)

    if files then
      local text = lead .. raw
      local h = {}
      if lead_hl then table.insert(h, { col = 0, end_col = 1, hl = lead_hl }) end
      local base = #lead
      table.insert(h, { col = base, end_col = base + #raw, hl = "JujutsuSubtle" })
      if ins and ins > 0 then
        local s, e = raw:find(tostring(ins) .. " insertions?", 1, true)
        if s then table.insert(h, { col = base + s - 1, end_col = base + e, hl = "JujutsuStatAdd" }) end
      end
      if dels and dels > 0 then
        local s, e = raw:find(tostring(dels) .. " deletions?", 1, true)
        if s then table.insert(h, { col = base + s - 1, end_col = base + e, hl = "JujutsuStatDelete" }) end
      end
      add(text, h)
    else
      local path, rest = raw:match("^(.-)%s+|%s+(.*)$")
      if not path then
        local text = lead .. raw
        local h = {}
        if lead_hl then table.insert(h, { col = 0, end_col = 1, hl = lead_hl }) end
        table.insert(h, { col = #lead, end_col = #text, hl = "JujutsuSubtle" })
        add(text, h)
      else
        local text = lead .. raw
        local h = {}
        if lead_hl then table.insert(h, { col = 0, end_col = 1, hl = lead_hl }) end
        local base = #lead
        local path_pos = raw:find(path, 1, true) or 1
        table.insert(h, {
          col = base + path_pos - 1,
          end_col = base + path_pos - 1 + #path,
          hl = "Normal",
        })
        local bar = raw:find("|", 1, true)
        if bar then
          table.insert(h, { col = base + bar - 1, end_col = base + bar, hl = "JujutsuSubtle" })
          local rest_pos = raw:find(rest, bar, true)
          if rest_pos then
            for j = 1, #rest do
              local ch = rest:sub(j, j)
              local abs = base + rest_pos - 1 + j - 1
              if ch == "+" then
                table.insert(h, { col = abs, end_col = abs + 1, hl = "JujutsuStatAdd" })
              elseif ch == "-" then
                table.insert(h, { col = abs, end_col = abs + 1, hl = "JujutsuStatDelete" })
              elseif ch:match("[%d()]") or ch == " " then
                table.insert(h, { col = abs, end_col = abs + 1, hl = "JujutsuSubtle" })
              end
            end
          end
        end
        add(text, h)
      end
    end
  end

  return lines, highlights
end

---@param root string
---@param rev string
function M.open(root, rev)
  require("jujutsu.hl").setup()

  local info = fetch_meta(root, rev)
  local stat_lines = fetch_stat(root, rev)
  local lines, highlights = build_render(info, stat_lines)

  local buf = Buffer.create("jujutsu://stat/" .. rev, "jujutsu-stat")
  Buffer.open(buf, (config.values.stat_view and config.values.stat_view.kind) or "vsplit")
  Buffer.render(buf, lines, highlights)

  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
  vim.keymap.set("n", "<esc>", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

return M
