local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local hunks_mod = require("jujutsu.diff.hunks")
local status_data = require("jujutsu.jj.status")
local watcher = require("jujutsu.watcher")

local M = {}

local SIGN_GROUP = "jujutsu_signs"
local NS = vim.api.nvim_create_namespace("jujutsu_signs")

---@class SignsBufState
---@field root string
---@field path string
---@field timer uv.uv_timer_t|nil
---@field attached boolean

---@type table<integer, SignsBufState>
local buffers = {}

---@type integer|nil
local autocmd_group = nil

---@type table<string, boolean>
local watched_roots = {}

local SIGN_HL = {
  add = "JujutsuSignsAdd",
  change = "JujutsuSignsChange",
  delete = "JujutsuSignsDelete",
  topdelete = "JujutsuSignsDelete",
  changedelete = "JujutsuSignsChange",
}

local function signs_cfg() return config.values.signs or {} end

local function define_signs()
  local cfg = signs_cfg()
  for name, hl in pairs(SIGN_HL) do
    local entry = cfg[name] or {}
    vim.fn.sign_define("JujutsuSign" .. name, {
      text = entry.text or "",
      texthl = hl,
      numhl = "",
      linehl = "",
    })
  end
end

---@param abs string
---@param root string
---@return string|nil
local function relpath(abs, root)
  abs = vim.fn.fnamemodify(abs, ":p")
  root = vim.fn.fnamemodify(root, ":p")
  if root:sub(-1) ~= "/" then root = root .. "/" end
  if abs:sub(1, #root) ~= root then return nil end
  return abs:sub(#root + 1)
end

---@param bufnr integer
---@return string|nil root
---@return string|nil path
local function buffer_repo_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil, nil end
  local abs = vim.fn.fnamemodify(name, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")
  local root = cli.find_workspace_root(dir)
  if not root then return nil, nil end
  local path = relpath(abs, root)
  return root, path
end

---Map unified hunks to gitsigns-style per-line sign kinds on the new file.
---@param hunks DiffHunk[]
---@return table<integer, string> line -> add|change|delete|topdelete|changedelete
local function signs_from_hunks(hunks)
  ---@type table<integer, string>
  local result = {}

  for _, hunk in ipairs(hunks) do
    local new_lnum = hunk.new_start
    local i = 1
    local lines = hunk.lines or {}

    while i <= #lines do
      local prefix = lines[i]:sub(1, 1)
      if prefix == "-" or prefix == "+" then
        local ndel, nadd = 0, 0
        while i <= #lines and lines[i]:sub(1, 1) == "-" do
          ndel = ndel + 1
          i = i + 1
        end
        while i <= #lines and lines[i]:sub(1, 1) == "+" do
          nadd = nadd + 1
          i = i + 1
        end

        if nadd == 0 and ndel > 0 then
          if new_lnum <= 0 or hunk.new_count == 0 then
            result[1] = "topdelete"
          else
            -- Show deletion on the following line in the new file
            result[new_lnum] = result[new_lnum] == "add" and "changedelete" or "delete"
          end
        elseif ndel == 0 and nadd > 0 then
          for _ = 1, nadd do
            result[new_lnum] = "add"
            new_lnum = new_lnum + 1
          end
        else
          local paired = math.min(ndel, nadd)
          for j = 1, paired do
            if j == paired and ndel > nadd then
              result[new_lnum] = "changedelete"
            else
              result[new_lnum] = "change"
            end
            new_lnum = new_lnum + 1
          end
          for _ = paired + 1, nadd do
            result[new_lnum] = "add"
            new_lnum = new_lnum + 1
          end
        end
      elseif prefix == " " then
        new_lnum = new_lnum + 1
        i = i + 1
      else
        i = i + 1
      end
    end
  end

  return result
end

---@param bufnr integer
local function clear_buf(bufnr)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

---@param bufnr integer
---@param line_signs table<integer, string>
local function place_buf(bufnr, line_signs)
  clear_buf(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for lnum, kind in pairs(line_signs) do
    if type(lnum) == "number" and lnum >= 1 and lnum <= line_count then
      vim.fn.sign_place(0, SIGN_GROUP, "JujutsuSign" .. kind, bufnr, {
        lnum = lnum,
        priority = 10,
      })
    end
  end
end

---@param bufnr integer
local function refresh_buf(bufnr)
  if config.values.disable_signs then
    clear_buf(bufnr)
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].buftype ~= "" then return end

  local state = buffers[bufnr]
  if not state or not state.attached then return end

  local root, path = buffer_repo_path(bufnr)
  if not root or not path or path == "" then
    clear_buf(bufnr)
    return
  end
  state.root = root
  state.path = path

  local diff_lines = status_data.file_diff(root, path)
  if not diff_lines or #diff_lines == 0 then
    clear_buf(bufnr)
    return
  end

  local hunks = hunks_mod.parse_hunks(diff_lines)
  local line_signs = signs_from_hunks(hunks)
  place_buf(bufnr, line_signs)
end

---@param bufnr integer
local function schedule_refresh(bufnr)
  local state = buffers[bufnr]
  if not state then return end
  if state.timer then
    state.timer:stop()
  else
    state.timer = vim.uv.new_timer()
  end
  state.timer:start(100, 0, function()
    vim.schedule(function() refresh_buf(bufnr) end)
  end)
end

---@param root string
local function ensure_root_watcher(root)
  if watched_roots[root] then return end
  watched_roots[root] = true
  watcher.start(root, function() M.refresh_all() end, "signs:" .. root)
end

---@param bufnr integer
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if config.values.disable_signs then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].buftype ~= "" then return end

  local root, path = buffer_repo_path(bufnr)
  if not root or not path then return end

  local state = buffers[bufnr]
  if state and state.attached then
    schedule_refresh(bufnr)
    return
  end

  buffers[bufnr] = {
    root = root,
    path = path,
    attached = true,
    timer = nil,
  }
  ensure_root_watcher(root)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    group = autocmd_group,
    callback = function() M.detach(bufnr) end,
  })

  schedule_refresh(bufnr)
end

---@param bufnr integer
function M.detach(bufnr)
  local state = buffers[bufnr]
  if not state then return end
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  clear_buf(bufnr)
  buffers[bufnr] = nil
end

function M.refresh_all()
  if config.values.disable_signs then
    for bufnr in pairs(buffers) do
      clear_buf(bufnr)
    end
    return
  end
  for bufnr, state in pairs(buffers) do
    if state.attached and vim.api.nvim_buf_is_valid(bufnr) then schedule_refresh(bufnr) end
  end
end

function M.setup()
  define_signs()

  if autocmd_group then
    vim.api.nvim_clear_autocmds({ group = autocmd_group })
  else
    autocmd_group = vim.api.nvim_create_augroup("JujutsuSigns", { clear = true })
  end

  if config.values.disable_signs then
    for bufnr in pairs(buffers) do
      M.detach(bufnr)
    end
    for root in pairs(watched_roots) do
      watcher.stop("signs:" .. root)
    end
    watched_roots = {}
    return
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = autocmd_group,
    callback = function(args) M.attach(args.buf) end,
  })

  vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
    group = autocmd_group,
    callback = function(args)
      if buffers[args.buf] then
        schedule_refresh(args.buf)
      else
        M.attach(args.buf)
      end
    end,
  })

  -- Attach currently open buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then M.attach(bufnr) end
  end
end

return M
