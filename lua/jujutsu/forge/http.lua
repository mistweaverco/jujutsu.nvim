local M = {}

---@param value any
---@return string
local function one_line(value) return (tostring(value or ""):gsub("[\r\n]+", " | ")) end

---@class ForgeHttpResult
---@field body string
---@field status integer|nil
---@field json table|nil
---@field err string|nil

---@param method string
---@param url string
---@param headers table<string, string>
---@param data? string
---@return ForgeHttpResult
function M.request(method, url, headers, data)
  if vim.fn.executable("curl") ~= 1 then return { body = "", status = nil, err = "curl is not on PATH" } end

  local args = { "curl", "-sS", "-X", method }
  for key, value in pairs(headers or {}) do
    if value ~= nil then
      table.insert(args, "-H")
      table.insert(args, string.format("%s: %s", key, value))
    end
  end
  if data then
    table.insert(args, "--data-raw")
    table.insert(args, data)
  end
  table.insert(args, "-w")
  table.insert(args, "\n__JJ_HTTP_CODE:%{http_code}")
  table.insert(args, url)

  local obj = vim.system(args, { text = true }):wait()
  if obj.code ~= 0 then
    local err = "curl exited with code " .. tostring(obj.code)
    if obj.stderr and obj.stderr ~= "" then err = err .. ": " .. one_line(obj.stderr) end
    return { body = "", status = nil, err = err }
  end

  local raw = obj.stdout or ""
  local body = raw
  local http_status = nil
  local marker_start, _, status_str = raw:find("\n?__JJ_HTTP_CODE:(%d+)%s*$")
  if marker_start then
    body = raw:sub(1, marker_start - 1)
    http_status = tonumber(status_str)
  end

  if http_status and (http_status < 200 or http_status >= 300) then
    local msg = one_line(body)
    if msg == "" then return { body = body, status = http_status, err = string.format("HTTP %d", http_status) } end
    return { body = body, status = http_status, err = string.format("HTTP %d: %s", http_status, msg) }
  end

  local json = nil
  if body ~= "" then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok then json = decoded end
  end

  return { body = body, status = http_status, json = json }
end

---@param user string
---@param token string
---@return string
-- luacheck: ignore 631
function M.basic_auth(user, token) return "Basic " .. vim.base64.encode(string.format("%s:%s", user or "", token or "")) end

return M
