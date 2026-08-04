local M = {}

---@class ForgeLabel
---@field name string
---@field color? string hex bg without or with leading #
---@field text_color? string hex fg without or with leading #

local cache = {}

---@param hex string|nil
---@return string|nil
local function normalize_hex(hex)
  if type(hex) ~= "string" or hex == "" then return nil end
  hex = hex:gsub("^#", "")
  if not hex:match("^%x%x%x%x%x%x$") then return nil end
  return "#" .. hex:lower()
end

---@param hex string
---@return integer, integer, integer
local function rgb(hex)
  hex = hex:gsub("^#", "")
  return tonumber(hex:sub(1, 2), 16) or 0, tonumber(hex:sub(3, 4), 16) or 0, tonumber(hex:sub(5, 6), 16) or 0
end

---Relative luminance (sRGB) for contrast decisions.
---@param hex string
---@return number
local function luminance(hex)
  local r, g, b = rgb(hex)
  local function chan(c)
    c = c / 255
    if c <= 0.03928 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)
end

---@param bg string
---@return string
local function contrasting_fg(bg)
  if luminance(bg) > 0.45 then return "#1a1a1a" end
  return "#ffffff"
end

---Map forge API labels into ForgeLabel[].
---@param labels any
---@param opts? { color_key?: string, text_color_key?: string, github?: boolean }
---@return ForgeLabel[]
function M.map(labels, opts)
  opts = opts or {}
  local color_key = opts.color_key or "color"
  local text_key = opts.text_color_key or "text_color"
  local out = {}
  if type(labels) ~= "table" then return out end
  for _, l in ipairs(labels) do
    if type(l) == "string" then
      table.insert(out, { name = l })
    elseif type(l) == "table" then
      local name = l.name or l.title or tostring(l.id or "?")
      local color = l[color_key]
      if opts.github and type(color) == "string" and color ~= "" and not color:match("^#") then color = "#" .. color end
      table.insert(out, {
        name = name,
        color = normalize_hex(color),
        text_color = normalize_hex(l[text_key]),
      })
    end
  end
  return out
end

---@param labels ForgeLabel[]|string[]|nil
---@return string[]
function M.names(labels)
  local out = {}
  if type(labels) ~= "table" then return out end
  for _, l in ipairs(labels) do
    if type(l) == "string" then
      table.insert(out, l)
    elseif type(l) == "table" and l.name then
      table.insert(out, l.name)
    end
  end
  return out
end

---Ensure labels are ForgeLabel[] (accepts legacy string[]).
---@param labels any
---@return ForgeLabel[]
function M.normalize(labels)
  if type(labels) ~= "table" then return {} end
  local out = {}
  for _, l in ipairs(labels) do
    if type(l) == "string" and l ~= "" then
      table.insert(out, { name = l })
    elseif type(l) == "table" and type(l.name) == "string" and l.name ~= "" then
      table.insert(out, {
        name = l.name,
        color = normalize_hex(l.color),
        text_color = normalize_hex(l.text_color),
      })
    end
  end
  return out
end

---@param label ForgeLabel
---@return string highlight group name
function M.hl_group(label)
  local bg = normalize_hex(label.color)
  if not bg then return "JujutsuIssueLabel" end
  local fg = normalize_hex(label.text_color) or contrasting_fg(bg)
  local key = bg:sub(2) .. "_" .. fg:sub(2)
  local group = "JujutsuLabel_" .. key
  if not cache[group] then
    pcall(vim.api.nvim_set_hl, 0, group, { bg = bg, fg = fg })
    cache[group] = true
  end
  return group
end

---@param label ForgeLabel
---@return string
function M.display(label)
  if type(label) == "string" then return label end
  return (label and label.name) or "?"
end

return M
