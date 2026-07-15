local notify = require("jujutsu.notify")
local spinner = require("jujutsu.spinner")
local util = require("jujutsu.util")

---@class ProcessResult
---@field stdout string[]
---@field stderr string[]
---@field code integer
---@field time number
---@field cmd string

---@class ProcessOpts
---@field cmd string[]
---@field cwd? string
---@field env? table<string, string>
---@field input? string
---@field suppress_console? boolean
---@field on_error? fun(res: ProcessResult): boolean

local M = {}

---@param opts ProcessOpts
---@param cb? fun(res: ProcessResult)
---@return ProcessResult|nil
function M.run(opts, cb)
  local cmd = opts.cmd
  local show_spinner = not opts.suppress_console
  if show_spinner then spinner.start(table.concat(cmd, " ")) end
  local start = vim.uv.now()
  local stdout, stderr = {}, {}
  local stdout_buf, stderr_buf = "", ""

  local function append(acc, buf, data)
    if not data or data == "" then return buf end
    -- vim.system may pass a string; coerce defensively
    if type(data) ~= "string" then data = tostring(data) end
    buf = buf .. data
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      -- gsub returns (str, count); parens discard the count so insert gets one value
      table.insert(acc, (buf:sub(1, nl - 1):gsub("\r$", "")))
      buf = buf:sub(nl + 1)
    end
    return buf
  end

  local env = nil
  if opts.env and next(opts.env) then
    env = vim.tbl_extend("force", vim.fn.environ(), opts.env)
    env.TERM = env.TERM or "xterm-256color"
  end

  local function finish(code)
    if show_spinner then spinner.stop() end
    if stdout_buf ~= "" then table.insert(stdout, stdout_buf) end
    if stderr_buf ~= "" then table.insert(stderr, stderr_buf) end
    ---@type ProcessResult
    local res = {
      stdout = stdout,
      stderr = stderr,
      code = code or -1,
      time = (vim.uv.now() - start) / 1000,
      cmd = table.concat(cmd, " "),
    }

    if code ~= 0 and not opts.suppress_console then
      local on_error = opts.on_error
      local show = true
      if on_error then show = on_error(res) end
      if show then
        local err = table.concat(util.remove_ansi_lines(util.trim_blank(stderr)), "\n")
        if err == "" then err = table.concat(util.remove_ansi_lines(util.trim_blank(stdout)), "\n") end
        if err ~= "" then notify.error(err) end
      end
    end

    -- Record in command history
    pcall(function() require("jujutsu.history").push(res) end)

    if cb then cb(res) end
    return res
  end

  local sys_opts = {
    cwd = opts.cwd,
    stdin = opts.input,
    text = true,
  }
  if env then sys_opts.env = env end

  if cb then
    sys_opts.stdout = function(_, data) stdout_buf = append(stdout, stdout_buf, data) end
    sys_opts.stderr = function(_, data) stderr_buf = append(stderr, stderr_buf, data) end
    vim.system(cmd, sys_opts, function(obj)
      vim.schedule(function() finish(obj.code) end)
    end)
    return nil
  end

  -- Sync
  local obj = vim.system(cmd, sys_opts):wait()
  stdout = vim.split(obj.stdout or "", "\n", { plain = true })
  stderr = vim.split(obj.stderr or "", "\n", { plain = true })
  -- Drop trailing empty from split
  if stdout[#stdout] == "" then table.remove(stdout) end
  if stderr[#stderr] == "" then table.remove(stderr) end
  return finish(obj.code)
end

---Run and await inside async coroutine.
---@param opts ProcessOpts
---@return ProcessResult
function M.await(opts)
  local async = require("jujutsu.async")
  return async.await(function(cb) M.run(opts, cb) end)
end

return M
