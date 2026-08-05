local M = {}

---@class CursorPushOpts
---@field insert_capable? boolean float uses real insert mode (comment/body prompt)

local VER_TYPING = "n:ver25,i:ver25-blink,r:hor20,o:hor50"

---@type string|nil
local saved_guicursor = nil
---@type integer
local depth = 0
---@type integer
local insert_capable_depth = 0
---@type integer|nil
local mode_au_group = nil

---@param spec string
---@return string|nil
local function normal_part(spec)
  if not spec or spec == "" then return "n:block-vCursor" end
  for part in spec:gmatch("[^,]+") do
    if part:match("^n:") or part:match("^n%-") then return part end
  end
  return "n:block-vCursor"
end

---@param spec string
---@return string
local function other_parts(spec)
  local out = {}
  if not spec or spec == "" then return "r:hor20,o:hor50" end
  for part in spec:gmatch("[^,]+") do
    if not part:match("^n:") and not part:match("^n%-") and not part:match("^i:") and not part:match("^i%-") then
      table.insert(out, part)
    end
  end
  if #out == 0 then return "r:hor20,o:hor50" end
  return table.concat(out, ",")
end

local function clear_mode_listener()
  if mode_au_group then
    pcall(vim.api.nvim_del_augroup_by_id, mode_au_group)
    mode_au_group = nil
  end
end

local function apply_float_cursor()
  if depth <= 0 then return end
  local mode = vim.api.nvim_get_mode().mode
  if insert_capable_depth > 0 and not mode:match("^[iR]") then
    local n = normal_part(saved_guicursor or "")
    vim.o.guicursor = n .. ",i:ver25-blink," .. other_parts(saved_guicursor or "")
    return
  end
  vim.o.guicursor = VER_TYPING
end

local function ensure_mode_listener()
  if mode_au_group then return end
  mode_au_group = vim.api.nvim_create_augroup("JujutsuTypingCursor", { clear = true })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = mode_au_group,
    callback = function()
      if depth > 0 then
        apply_float_cursor()
        pcall(vim.cmd, "redraw")
      end
    end,
  })
end

---@param opts? CursorPushOpts
function M.push_typing(opts)
  opts = opts or {}
  depth = depth + 1
  if opts.insert_capable then insert_capable_depth = insert_capable_depth + 1 end
  if depth == 1 then
    saved_guicursor = vim.o.guicursor
    ensure_mode_listener()
  end
  apply_float_cursor()
end

---@param opts? CursorPushOpts
function M.pop_typing(opts)
  opts = opts or {}
  if depth <= 0 then return end
  depth = depth - 1
  if opts.insert_capable then insert_capable_depth = math.max(0, insert_capable_depth - 1) end

  if depth > 0 then
    apply_float_cursor()
    return
  end

  clear_mode_listener()
  local restore = saved_guicursor or ""
  saved_guicursor = nil
  insert_capable_depth = 0

  local function do_restore()
    vim.o.guicursor = restore
    pcall(vim.cmd, "redraw")
  end
  do_restore()
  vim.schedule(do_restore)
  vim.defer_fn(do_restore, 10)
end

return M
