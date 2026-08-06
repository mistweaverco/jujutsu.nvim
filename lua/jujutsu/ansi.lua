local M = {}

---@type table<string, boolean>
local hl_cache = {}

---@return { fg: string[], bright_fg: string[], bg: string[], bright_bg: string[] }
local function palette()
  local dark = vim.o.background ~= "light"
  if dark then
    return {
      fg = { "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5" },
      bright_fg = { "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff" },
      bg = { "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5" },
      bright_bg = { "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff" },
    }
  end
  return {
    fg = { "#000000", "#cd3131", "#00bc00", "#949800", "#0451a5", "#bc05bc", "#0598bc", "#555555" },
    bright_fg = { "#666666", "#cd3131", "#14ce14", "#b5ba00", "#0451a5", "#bc05bc", "#0598bc", "#a5a5a5" },
    bg = { "#000000", "#cd3131", "#00bc00", "#949800", "#0451a5", "#bc05bc", "#0598bc", "#555555" },
    bright_bg = { "#666666", "#cd3131", "#14ce14", "#b5ba00", "#0451a5", "#bc05bc", "#0598bc", "#a5a5a5" },
  }
end

---@class AnsiAttrs
---@field bold boolean
---@field italic boolean
---@field underline boolean
---@field fg? integer 0-7
---@field fg_bright boolean
---@field bg? integer 0-7
---@field bg_bright boolean
---@field fg256? integer
---@field bg256? integer
---@field fg_rgb? string
---@field bg_rgb? string

---@return AnsiAttrs
local function default_attrs()
  return {
    bold = false,
    italic = false,
    underline = false,
    fg = nil,
    fg_bright = false,
    bg = nil,
    bg_bright = false,
    fg256 = nil,
    bg256 = nil,
    fg_rgb = nil,
    bg_rgb = nil,
  }
end

---@param attrs AnsiAttrs
---@return AnsiAttrs
local function reset_attrs(attrs)
  local fresh = default_attrs()
  for k, v in pairs(fresh) do
    attrs[k] = v
  end
  return attrs
end

---@param codes integer[]
---@param attrs AnsiAttrs
local function apply_sgr(codes, attrs)
  local i = 1
  while i <= #codes do
    local c = codes[i]
    if c == 0 then
      reset_attrs(attrs)
    elseif c == 1 or c == 21 then
      attrs.bold = true
    elseif c == 22 then
      attrs.bold = false
    elseif c == 3 then
      attrs.italic = true
    elseif c == 23 then
      attrs.italic = false
    elseif c == 4 then
      attrs.underline = true
    elseif c == 24 then
      attrs.underline = false
    elseif c >= 30 and c <= 37 then
      attrs.fg = c - 30
      attrs.fg_bright = false
      attrs.fg256 = nil
      attrs.fg_rgb = nil
    elseif c >= 90 and c <= 97 then
      attrs.fg = c - 90
      attrs.fg_bright = true
      attrs.fg256 = nil
      attrs.fg_rgb = nil
    elseif c >= 40 and c <= 47 then
      attrs.bg = c - 40
      attrs.bg_bright = false
      attrs.bg256 = nil
      attrs.bg_rgb = nil
    elseif c >= 100 and c <= 107 then
      attrs.bg = c - 100
      attrs.bg_bright = true
      attrs.bg256 = nil
      attrs.bg_rgb = nil
    elseif c == 39 then
      attrs.fg = nil
      attrs.fg_bright = false
      attrs.fg256 = nil
      attrs.fg_rgb = nil
    elseif c == 49 then
      attrs.bg = nil
      attrs.bg_bright = false
      attrs.bg256 = nil
      attrs.bg_rgb = nil
    elseif c == 38 and codes[i + 1] == 5 and codes[i + 2] then
      attrs.fg = nil
      attrs.fg_bright = false
      attrs.fg_rgb = nil
      attrs.fg256 = codes[i + 2]
      i = i + 2
    elseif c == 38 and codes[i + 1] == 2 and codes[i + 4] then
      attrs.fg = nil
      attrs.fg_bright = false
      attrs.fg256 = nil
      attrs.fg_rgb = string.format("#%02x%02x%02x", codes[i + 2], codes[i + 3], codes[i + 4])
      i = i + 4
    elseif c == 48 and codes[i + 1] == 5 and codes[i + 2] then
      attrs.bg = nil
      attrs.bg_bright = false
      attrs.bg_rgb = nil
      attrs.bg256 = codes[i + 2]
      i = i + 2
    elseif c == 48 and codes[i + 1] == 2 and codes[i + 4] then
      attrs.bg = nil
      attrs.bg_bright = false
      attrs.bg256 = nil
      attrs.bg_rgb = string.format("#%02x%02x%02x", codes[i + 2], codes[i + 3], codes[i + 4])
      i = i + 4
    end
    i = i + 1
  end
end

---@param param_str string
---@return integer[]
local function parse_params(param_str)
  if param_str == "" then return { 0 } end
  local codes = {}
  for num in param_str:gmatch("%d+") do
    table.insert(codes, tonumber(num))
  end
  if #codes == 0 then return { 0 } end
  return codes
end

---@param n integer
---@return string
local function cube256(n)
  if n < 16 then
    local bases = {
      "#000000",
      "#800000",
      "#008000",
      "#808000",
      "#000080",
      "#800080",
      "#008080",
      "#c0c0c0",
      "#808080",
      "#ff0000",
      "#00ff00",
      "#ffff00",
      "#0000ff",
      "#ff00ff",
      "#00ffff",
      "#ffffff",
    }
    return bases[n + 1] or "#ffffff"
  end
  if n >= 232 then
    local shade = (n - 232) * 10 + 8
    return string.format("#%02x%02x%02x", shade, shade, shade)
  end
  n = n - 16
  local r = math.floor(n / 36)
  local g = math.floor((n % 36) / 6)
  local b = n % 6
  local function comp(v)
    if v == 0 then return 0 end
    return 55 + (v - 1) * 40
  end
  return string.format("#%02x%02x%02x", comp(r), comp(g), comp(b))
end

---@param attrs AnsiAttrs
---@return string|nil
local function hl_group_for(attrs)
  local has_style = attrs.bold or attrs.italic or attrs.underline
  local has_color = attrs.fg ~= nil
    or attrs.bg ~= nil
    or attrs.fg256 ~= nil
    or attrs.bg256 ~= nil
    or attrs.fg_rgb ~= nil
    or attrs.bg_rgb ~= nil
  if not has_style and not has_color then return nil end

  local key = string.format(
    "JujutsuAnsi_%d%d%d_%s_%s_%s_%s_%s_%s",
    attrs.bold and 1 or 0,
    attrs.italic and 1 or 0,
    attrs.underline and 1 or 0,
    attrs.fg and tostring(attrs.fg) or "n",
    attrs.fg_bright and "b" or "n",
    attrs.bg and tostring(attrs.bg) or "n",
    attrs.bg_bright and "b" or "n",
    attrs.fg256 and tostring(attrs.fg256) or (attrs.fg_rgb or "n"),
    attrs.bg256 and tostring(attrs.bg256) or (attrs.bg_rgb or "n")
  )

  if hl_cache[key] then return key end

  local p = palette()
  local opts = {}
  if attrs.bold then opts.bold = true end
  if attrs.italic then opts.italic = true end
  if attrs.underline then opts.underline = true end

  if attrs.fg_rgb then
    opts.fg = attrs.fg_rgb
  elseif attrs.fg256 ~= nil then
    opts.fg = cube256(attrs.fg256)
  elseif attrs.fg ~= nil then
    local colors = attrs.fg_bright and p.bright_fg or p.fg
    opts.fg = colors[attrs.fg + 1]
  end

  if attrs.bg_rgb then
    opts.bg = attrs.bg_rgb
  elseif attrs.bg256 ~= nil then
    opts.bg = cube256(attrs.bg256)
  elseif attrs.bg ~= nil then
    local colors = attrs.bg_bright and p.bright_bg or p.bg
    opts.bg = colors[attrs.bg + 1]
  end

  vim.api.nvim_set_hl(0, key, opts)
  hl_cache[key] = true
  return key
end

function M.clear_hl_cache() hl_cache = {} end

---GitHub `gh run view --log` emits caret escapes: `^[` = ESC, then `[36m` is the CSI body.
---@param line string
---@return string
function M.normalize_escapes(line) return (line:gsub("%^%[", "\27")) end

---@param line string
---@return { text: string, hl?: string }[]
function M.parse_segments(line)
  line = M.normalize_escapes(line)
  local segments = {}
  local attrs = default_attrs()
  local pos = 1

  while pos <= #line do
    local esc_start, esc_end, params = line:find("\27%[([0-9;]*)m", pos)
    if esc_start and esc_start == pos then
      apply_sgr(parse_params(params or ""), attrs)
      pos = esc_end + 1
    elseif esc_start then
      local text = line:sub(pos, esc_start - 1)
      if text ~= "" then table.insert(segments, { text = text, hl = hl_group_for(attrs) }) end
      apply_sgr(parse_params(params or ""), attrs)
      pos = esc_end + 1
    else
      local text = line:sub(pos)
      if text ~= "" then table.insert(segments, { text = text, hl = hl_group_for(attrs) }) end
      break
    end
  end

  return segments
end

---@param line string
---@return string
function M.strip(line)
  line = M.normalize_escapes(line)
  return (line:gsub("\27%[[0-9;]*m", ""))
end

---@param line string
---@param row integer 0-based buffer line
---@param col_offset? integer
---@return string plain
---@return table[] highlights for Buffer.render
function M.line_to_highlights(line, row, col_offset)
  col_offset = col_offset or 0
  local segments = M.parse_segments(line)
  local plain_parts = {}
  local highlights = {}
  local col = col_offset

  for _, seg in ipairs(segments) do
    table.insert(plain_parts, seg.text)
    if seg.hl then
      table.insert(highlights, {
        line = row,
        col = col,
        end_col = col + #seg.text,
        hl = seg.hl,
      })
    end
    col = col + #seg.text
  end

  return table.concat(plain_parts, ""), highlights
end

return M
