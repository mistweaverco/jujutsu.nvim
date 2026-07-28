local M = {}

---Marker prefixed to each revision's template so graph edges can be split off.
M.SENTINEL = "\x01"

---Builtin jj node glyphs (unicode + ascii variants) that we may rewrite.
local BUILTIN_NODES = { "@", "◆", "○", "×", "~", "+", "o", "x" }

---@param line string
---@return string graph_prefix
---@return string|nil fields rest after sentinel, or nil for graph-only lines
function M.split_line(line)
  local s, e = line:find(M.SENTINEL, 1, true)
  if not s then return line, nil end
  return line:sub(1, s - 1), line:sub(e + 1)
end

---@param symbols table
---@param meta { working_copy?: boolean, immutable?: boolean, conflict?: boolean, elided?: boolean }
---@return string
function M.node_symbol(symbols, meta)
  if meta.elided then return symbols.elided or "~" end
  if meta.working_copy then return symbols.working_copy or "@" end
  if meta.immutable then return symbols.immutable or "◆" end
  if meta.conflict then return symbols.conflict or "×" end
  return symbols.mutable or "○"
end

---Replace the builtin node glyph in a jj graph prefix with `symbol`.
---@param prefix string
---@param symbol string
---@return string
function M.rewrite_node(prefix, symbol)
  for _, node in ipairs(BUILTIN_NODES) do
    local idx = prefix:find(node, 1, true)
    if idx then return prefix:sub(1, idx - 1) .. symbol .. prefix:sub(idx + #node) end
  end
  return prefix
end

---Rewrite elided `~` on graph-only connector/elided lines when configured.
---@param prefix string
---@param symbol string
---@return string
function M.rewrite_elided(prefix, symbol)
  if symbol == "~" then return prefix end
  local idx = prefix:find("~", 1, true)
  if idx then return prefix:sub(1, idx - 1) .. symbol .. prefix:sub(idx + 1) end
  return prefix
end

return M
