local lualine_require = require("lualine_require")
local modules = lualine_require.lazy_require({
  utils = "lualine.utils.utils",
})
local M = lualine_require.require("lualine.component"):extend()
local jujutsu = require("jujutsu.lualine")

local default_options = {
  colored = true,
}

---@param name string
---@return fun(): { fg?: string, gui?: string }
local function color_from(name)
  return function()
    local fg = modules.utils.extract_highlight_colors(name, "fg")
    if fg then return { fg = fg, gui = "bold" } end
    return { gui = "bold" }
  end
end

function M:init(options)
  M.super.init(self, options)
  self.options = vim.tbl_deep_extend("keep", self.options or {}, default_options)
  if self.options.colored then
    self.highlights = {
      rev = self:create_hl(color_from("JujutsuLualineRev"), "rev"),
      bookmark = self:create_hl(color_from("JujutsuLualineBookmark"), "bookmark"),
      add = self:create_hl(color_from("JujutsuLualineAdd"), "add"),
      change = self:create_hl(color_from("JujutsuLualineChange"), "change"),
      delete = self:create_hl(color_from("JujutsuLualineDelete"), "delete"),
    }
  end
end

function M:update_status()
  local segments = jujutsu.segments()
  if #segments == 0 then return "" end

  local colors = {}
  if self.options.colored then
    for key, hl in pairs(self.highlights) do
      colors[key] = self:format_hl(hl)
    end
  end

  local parts = {}
  for _, seg in ipairs(segments) do
    if self.options.colored and colors[seg.key] then
      parts[#parts + 1] = colors[seg.key] .. seg.text
    else
      parts[#parts + 1] = seg.text
    end
  end
  return table.concat(parts, " ")
end

return M
