local M = {}

---@type ProcessResult[]
local entries = {}
local max = 50

---@param res ProcessResult
function M.push(res)
  table.insert(entries, 1, res)
  while #entries > max do
    table.remove(entries)
  end
end

---@return ProcessResult[]
function M.list() return entries end

function M.clear() entries = {} end

return M
