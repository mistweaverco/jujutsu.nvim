local config = require("jujutsu.config")
local markdown = require("jujutsu.markdown")
local threads = require("jujutsu.review.threads")

local M = {}

local ns = vim.api.nvim_create_namespace("jujutsu_review_comments")

---@param buf integer|nil
function M.clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

---@param comments table[]
---@param path string
---@param side "LEFT"|"RIGHT"
---@return table<integer, table[]>
local function by_line(comments, path, side)
  local map = {}
  for _, c in ipairs(comments) do
    local kind = c.kind or "line"
    if c.path == path and (kind == "line" or kind == "range") and c.line then
      local cside = c.side or "RIGHT"
      if cside == side then
        local line = tonumber(c.line) or c.line
        map[line] = map[line] or {}
        table.insert(map[line], c)
      end
    end
  end
  return map
end

---@return { wrap: boolean, width: integer|nil, markdown: boolean, comment_indent: integer }
local function wrap_opts()
  local rev = (config.values.forge or {}).review or {}
  local wrap = rev.wrap_comments
  if wrap == nil then wrap = true end
  local width = rev.wrap_width
  if type(width) ~= "number" or width < 1 then width = nil end
  local md = rev.render_markdown
  if md == nil then md = true end
  local indent = rev.comment_indent
  if type(indent) ~= "number" or indent < 0 then indent = 4 end
  return {
    wrap = wrap and true or false,
    width = width,
    markdown = md and true or false,
    comment_indent = math.floor(indent),
  }
end

---@param buf integer
---@return integer
local function window_text_width(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local w = vim.api.nvim_win_get_width(win)
      if vim.wo[win].number or vim.wo[win].relativenumber then w = w - math.max(vim.wo[win].numberwidth or 4, 1) end
      if (vim.wo[win].signcolumn or "auto") ~= "no" then w = w - 2 end
      w = w - (tonumber(vim.wo[win].foldcolumn) or 0)
      return math.max(w, 20)
    end
  end
  return math.max(vim.o.columns - 4, 20)
end

---@param s string
---@return integer
local function dw(s) return vim.fn.strdisplaywidth(s) end

---Hard-break an overlong token into display-width chunks.
---@param word string
---@param width integer
---@return string[]
local function break_token(word, width)
  local chunks = {}
  local acc = ""
  for _, ch in ipairs(vim.fn.str2list(word)) do
    local c = vim.fn.nr2char(ch)
    if acc ~= "" and dw(acc .. c) > width then
      table.insert(chunks, acc)
      acc = c
    else
      acc = acc .. c
    end
  end
  if acc ~= "" then table.insert(chunks, acc) end
  return #chunks > 0 and chunks or { "" }
end

---@param chunks { [1]: string, [2]: any }[]
---@param text string
---@param hl any
local function push_chunk(chunks, text, hl)
  if text == "" then return end
  local last = chunks[#chunks]
  if last and last[2] == hl then
    last[1] = last[1] .. text
  else
    table.insert(chunks, { text, hl })
  end
end

---Explode highlighted chunks into per-character cells (UTF-8 safe).
---@param chunks { [1]: string, [2]: any }[]
---@return { c: string, hl: any }[]
local function explode_chunks(chunks)
  local chars = {}
  for _, ch in ipairs(chunks) do
    local hl = ch[2]
    for _, cp in ipairs(vim.fn.str2list(ch[1] or "")) do
      table.insert(chars, { c = vim.fn.nr2char(cp), hl = hl })
    end
  end
  return chars
end

---@param chars { c: string, hl: any }[]
---@return { [1]: string, [2]: any }[]
local function coalesce_chars(chars)
  local out = {}
  for _, cell in ipairs(chars) do
    push_chunk(out, cell.c, cell.hl)
  end
  if #out == 0 then return { { "", nil } } end
  return out
end

---Wrap body into plain lines. First line uses `first_width`, later lines use `cont_width`.
---@param text string
---@param first_width integer
---@param cont_width integer
---@return string[]
local function wrap_body(text, first_width, cont_width)
  first_width = math.max(first_width, 8)
  cont_width = math.max(cont_width, 8)
  local out = {}
  local first = true

  local function width() return first and first_width or cont_width end

  local function emit(line)
    table.insert(out, line)
    first = false
  end

  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if para == "" then
      emit("")
    else
      local current = ""
      for word in para:gmatch("%S+") do
        local w = width()
        if current == "" then
          if dw(word) <= w then
            current = word
          else
            for _, chunk in ipairs(break_token(word, w)) do
              emit(chunk)
            end
            current = ""
          end
        elseif dw(current) + 1 + dw(word) <= w then
          current = current .. " " .. word
        else
          emit(current)
          w = width()
          if dw(word) <= w then
            current = word
          else
            for _, chunk in ipairs(break_token(word, w)) do
              emit(chunk)
            end
            current = ""
          end
        end
      end
      if current ~= "" then emit(current) end
    end
  end

  if #out == 0 then return { "" } end
  return out
end

---Wrap highlighted markdown lines. First visual line uses `first_width`, later `cont_width`.
---@param chunk_lines { [1]: string, [2]: any }[][]
---@param first_width integer
---@param cont_width integer
---@param fallback_hl any
---@return { [1]: string, [2]: any }[][]
local function wrap_highlighted_body(chunk_lines, first_width, cont_width, fallback_hl)
  first_width = math.max(first_width, 8)
  cont_width = math.max(cont_width, 8)
  local out = {}
  local first = true

  local function budget() return first and first_width or cont_width end

  for _, chunks in ipairs(chunk_lines) do
    local normalized = {}
    for _, ch in ipairs(chunks) do
      push_chunk(normalized, ch[1], ch[2] or fallback_hl)
    end
    local chars = explode_chunks(normalized)
    if #chars == 0 then
      table.insert(out, { { "", fallback_hl } })
      first = false
    else
      local idx = 1
      while idx <= #chars do
        local width = budget()
        local line_chars = {}
        local line_w = 0
        while idx <= #chars do
          if chars[idx].c:match("%s") then
            local cw = dw(chars[idx].c)
            if #line_chars == 0 or line_w + cw <= width then
              table.insert(line_chars, chars[idx])
              line_w = line_w + cw
              idx = idx + 1
            else
              break
            end
          else
            local word, word_w = {}, 0
            local j = idx
            while j <= #chars and not chars[j].c:match("%s") do
              table.insert(word, chars[j])
              word_w = word_w + dw(chars[j].c)
              j = j + 1
            end
            if #line_chars == 0 then
              if word_w <= width then
                vim.list_extend(line_chars, word)
                line_w = word_w
                idx = j
              else
                for _, cell in ipairs(word) do
                  local cw = dw(cell.c)
                  if line_w > 0 and line_w + cw > width then
                    table.insert(out, coalesce_chars(line_chars))
                    first = false
                    width = budget()
                    line_chars = { cell }
                    line_w = cw
                  else
                    table.insert(line_chars, cell)
                    line_w = line_w + cw
                  end
                end
                idx = j
              end
            elseif line_w + word_w <= width then
              vim.list_extend(line_chars, word)
              line_w = line_w + word_w
              idx = j
            else
              break
            end
          end
        end
        while #line_chars > 0 and line_chars[#line_chars].c:match("%s") and idx <= #chars do
          table.remove(line_chars)
        end
        table.insert(out, coalesce_chars(line_chars))
        first = false
      end
    end
  end

  if #out == 0 then return { { { "", fallback_hl } } } end
  return out
end

---@param c table
---@return string
local function format_comment_time(c)
  local t = c.created_at or c.updated_at
  if t == nil or t == vim.NIL then return "" end
  if type(t) == "number" then
    return os.date("%Y-%m-%d %H:%M", t) --[[@as string]]
  end
  return require("jujutsu.issue_panel.model").format_time(t)
end

---@param c table
---@return { [1]: string, [2]: string }[] header_chunks, string body, string body_hl, string body_prefix
local function parts_for(c, opts)
  local depth = tonumber(c._thread_depth) or 0
  local depth_pad = string.rep("  ", depth)
  local body_prefix = string.rep(" ", opts.comment_indent) .. depth_pad
  local body = c.body or ""

  local marker = "  💬 "
  local reply = depth > 0 and "↳ " or ""
  local header_lead = marker .. depth_pad .. reply

  local author_hl = "JujutsuReviewAuthor"
  local body_hl = "JujutsuReviewComment"
  local name = "you"
  if c.remote then
    name = c.author or "remote"
    body_hl = depth > 0 and "JujutsuReviewReply" or "JujutsuReviewRemote"
  end

  local header = { { header_lead, body_hl }, { name, author_hl } }
  local when = format_comment_time(c)
  if when ~= "" then
    table.insert(header, { " · ", "JujutsuSubtle" })
    table.insert(header, { when, "JujutsuReviewDate" })
  end
  if c.outdated then table.insert(header, { " (outdated)", "JujutsuSubtle" }) end

  return header, body, body_hl, body_prefix
end

---@param body_chunks { [1]: string, [2]: any }[]
---@param max_width integer
---@param fallback_hl any
---@return { [1]: string, [2]: any }[]
local function truncate_chunks(body_chunks, max_width, fallback_hl)
  local chars = explode_chunks(body_chunks)
  local kept, w = {}, 0
  local ell = "..."
  local ell_w = dw(ell)
  for _, cell in ipairs(chars) do
    local cw = dw(cell.c)
    if w + cw > max_width then break end
    if w + cw + ell_w > max_width and (#chars > #kept + 1) then break end
    table.insert(kept, cell)
    w = w + cw
  end
  local out = coalesce_chars(kept)
  if #chars > #kept then push_chunk(out, ell, fallback_hl) end
  if #out == 0 then return { { "", fallback_hl } } end
  for _, ch in ipairs(out) do
    if ch[2] == nil then ch[2] = fallback_hl end
  end
  return out
end

---@param prefix string
---@param prefix_hl any
---@param body_chunks { [1]: string, [2]: any }[]
---@return { [1]: string, [2]: any }[]
local function with_prefix(prefix, prefix_hl, body_chunks)
  local row = { { prefix, prefix_hl } }
  for _, ch in ipairs(body_chunks) do
    push_chunk(row, ch[1], ch[2] or prefix_hl)
  end
  return row
end

---@param buf integer
---@param c table
---@param opts { wrap: boolean, width: integer|nil, markdown: boolean, comment_indent: integer }
---@return { [1]: string, [2]: any }[][]
local function virt_lines_for(buf, c, opts)
  local header, body, body_hl, body_prefix = parts_for(c, opts)
  local total_width = opts.width or window_text_width(buf)
  local body_budget = math.max(total_width - dw(body_prefix), 8)

  local lines = { header }

  ---@type { [1]: string, [2]: any }[][]|nil
  local highlighted = nil
  if opts.markdown then highlighted = markdown.highlight_lines(body) end

  if not highlighted then
    if not opts.wrap then
      local flat = body:gsub("\n", " ")
      if dw(flat) > body_budget then flat = vim.fn.strcharpart(flat, 0, math.max(body_budget - 3, 1)) .. "..." end
      table.insert(lines, { { body_prefix .. flat, body_hl } })
      return lines
    end
    for _, line in ipairs(wrap_body(body, body_budget, body_budget)) do
      table.insert(lines, { { body_prefix .. line, body_hl } })
    end
    return lines
  end

  if not opts.wrap then
    local flat_chunks = {}
    for i, line_chunks in ipairs(highlighted) do
      if i > 1 then push_chunk(flat_chunks, " ", body_hl) end
      for _, ch in ipairs(line_chunks) do
        push_chunk(flat_chunks, ch[1], ch[2] or body_hl)
      end
    end
    table.insert(lines, with_prefix(body_prefix, body_hl, truncate_chunks(flat_chunks, body_budget, body_hl)))
    return lines
  end

  for _, body_chunks in ipairs(wrap_highlighted_body(highlighted, body_budget, body_budget, body_hl)) do
    table.insert(lines, with_prefix(body_prefix, body_hl, body_chunks))
  end
  return lines
end

---@param buf integer
---@param comments table[]
---@param path string
---@param side "LEFT"|"RIGHT"
function M.render(buf, comments, path, side)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  M.clear(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local grouped = by_line(comments, path, side)
  local opts = wrap_opts()
  for line, list in pairs(grouped) do
    if line >= 1 and line <= line_count then
      local ordered = threads.order_for_overlay(list)
      local virt = {}
      local has_local = false
      for _, c in ipairs(ordered) do
        if not c.remote then has_local = true end
        for _, vl in ipairs(virt_lines_for(buf, c, opts)) do
          table.insert(virt, vl)
        end
      end
      local sign_hl = has_local and "JujutsuReviewSign" or "JujutsuReviewRemoteSign"
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
        sign_text = "💬",
        sign_hl_group = sign_hl,
        virt_lines = virt,
        virt_lines_above = false,
        priority = 1100,
      })
    end
  end
end

---@param comments table[]
---@param path string
---@param side "LEFT"|"RIGHT"
---@param from_line integer
---@param direction integer 1 or -1
---@return integer|nil
function M.next_comment_line(comments, path, side, from_line, direction)
  local lines = {}
  for line, _ in pairs(by_line(comments, path, side)) do
    table.insert(lines, line)
  end
  table.sort(lines)
  if #lines == 0 then return nil end
  if direction > 0 then
    for _, l in ipairs(lines) do
      if l > from_line then return l end
    end
    return lines[1]
  else
    for i = #lines, 1, -1 do
      if lines[i] < from_line then return lines[i] end
    end
    return lines[#lines]
  end
end

---All comment anchors for a path. One entry per line (RIGHT preferred over LEFT).
---@param comments table[]
---@param path string
---@return { side: "LEFT"|"RIGHT", line: integer }[]
function M.comment_targets(comments, path)
  local line_side = {}
  for _, c in ipairs(comments) do
    local kind = c.kind or "line"
    if c.path == path and (kind == "line" or kind == "range") and c.line then
      local side = c.side or "RIGHT"
      if side ~= "LEFT" and side ~= "RIGHT" then side = "RIGHT" end
      local line = tonumber(c.line) or c.line
      if not line_side[line] or side == "RIGHT" then line_side[line] = side end
    end
  end
  local out = {}
  for line, side in pairs(line_side) do
    table.insert(out, { side = side, line = line })
  end
  table.sort(out, function(a, b) return a.line < b.line end)
  return out
end

---Next/prev comment across both sides (for file-list navigation).
---@param comments table[]
---@param path string
---@param from_line integer
---@param direction integer 1 or -1
---@return { side: "LEFT"|"RIGHT", line: integer }|nil
function M.next_comment_target(comments, path, from_line, direction)
  local targets = M.comment_targets(comments, path)
  if #targets == 0 then return nil end
  if direction > 0 then
    for _, t in ipairs(targets) do
      if t.line > from_line then return t end
    end
    return targets[1]
  end
  for i = #targets, 1, -1 do
    if targets[i].line < from_line then return targets[i] end
  end
  return targets[#targets]
end

return M
