-- Minimal coroutine helpers (replaces plenary.async)
local M = {}

---@param fn fun(...)
---@param ... any
function M.void(fn, ...)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, a = coroutine.resume(co, ...)
    if not ok then error(debug.traceback(co, a), 0) end
    if coroutine.status(co) ~= "dead" and type(a) == "function" then
      -- a is a callback-style await continuation: function(resume)
      a(vim.schedule_wrap(step))
    end
  end
  step(...)
end

---Wrap a callback-style async function so it can be awaited inside a void/coroutine.
---@param fn fun(..., cb: fun(...))
---@param argc integer number of args before the callback
---@return fun(...): any
function M.wrap(fn, argc)
  return function(...)
    local co = coroutine.running()
    if not co then error("async.wrap called outside of a coroutine") end
    local args = { ... }
    return coroutine.yield(function(resume)
      args[argc + 1] = resume
      fn(unpack(args, 1, argc + 1))
    end)
  end
end

---Await a function that takes a callback as last arg.
---@param fn fun(..., cb: fun(...))
---@param ... any
---@return any
function M.await(fn, ...)
  local co = coroutine.running()
  if not co then error("async.await called outside of a coroutine") end
  local n = select("#", ...)
  local args = { ... }
  return coroutine.yield(function(resume)
    args[n + 1] = resume
    fn(unpack(args, 1, n + 1))
  end)
end

---Schedule and wait (sleep).
---@param ms integer
function M.sleep(ms)
  local co = coroutine.running()
  if not co then
    vim.wait(ms)
    return
  end
  return coroutine.yield(function(resume) vim.defer_fn(resume, ms) end)
end

return M
