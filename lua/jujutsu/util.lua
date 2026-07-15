local M = {}

---@param lines string[]
---@return string[]
function M.trim_blank(lines)
  return vim.tbl_filter(function(v) return v ~= "" end, lines)
end

---@param s string
---@return string
function M.remove_ansi(s) return (s:gsub("\27%[[0-9;]*[mK]", ""):gsub("\27%][^\7]*\7", "")) end

---@param lines string[]
---@return string[]
function M.remove_ansi_lines(lines) return vim.tbl_map(M.remove_ansi, lines) end

---@param list any[]
---@return table<any, boolean>
function M.reverse_lookup(list)
  local t = {}
  for _, v in ipairs(list or {}) do
    t[v] = true
  end
  return t
end

---@param tbl table
---@param item any
---@return boolean
function M.remove_item(tbl, item)
  for i, v in ipairs(tbl) do
    if v == item then
      table.remove(tbl, i)
      return true
    end
  end
  return false
end

---@param str string
---@return string
function M.trim(str) return (str:gsub("^%s+", ""):gsub("%s+$", "")) end

---@param path string
---@return string
function M.expand(path) return vim.fn.expand(path) end

---@param dir string
---@return string
function M.normalize_path(dir) return vim.fn.fnamemodify(dir, ":p"):gsub("/$", "") end

return M
