local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

---@param path string
---@return string
local function detect_filetype(path)
  local ft = vim.filetype.match({ filename = path })
  return ft or ""
end

---@param lines string[]|nil
---@return string[]
local function ensure_lines(lines)
  if not lines or #lines == 0 then return { "" } end
  return lines
end

---@param root string
---@param rev string
---@param path string
---@return string[]
local function file_show(root, rev, path)
  local res = cli.file_show.revision(rev).paths(path).call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if res.code ~= 0 then return {} end
  return res.stdout or {}
end

---@class DiffSplit
---@field left_buf Buffer
---@field right_buf Buffer
---@field left_win integer|nil
---@field right_win integer|nil
---@field root string
---@field uri_prefix string

---@param root string
---@param left_win integer
---@param right_win integer
---@param opts? { uri_prefix?: string }
---@return DiffSplit
function M.create(root, left_win, right_win, opts)
  opts = opts or {}
  local prefix = opts.uri_prefix or "jujutsu://diff"
  local left_buf = Buffer.create(prefix .. "/a", "jujutsu-diff-split")
  local right_buf = Buffer.create(prefix .. "/b", "jujutsu-diff-split")

  vim.api.nvim_win_set_buf(left_win, left_buf.bufnr)
  vim.api.nvim_win_set_buf(right_win, right_buf.bufnr)
  left_buf.winid = left_win
  right_buf.winid = right_win

  for _, win in ipairs({ left_win, right_win }) do
    vim.wo[win].foldenable = false
    vim.wo[win].wrap = false
    vim.wo[win].signcolumn = "auto"
    if config.values.disable_line_numbers then
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
    end
  end

  return {
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
    root = root,
    uri_prefix = prefix,
  }
end

---@param buf Buffer
---@param lines string[]
---@param name string
---@param ft string
local function set_content(buf, lines, name, ft)
  -- readonly and modifiable are independent; clear both before rewriting.
  vim.bo[buf.bufnr].readonly = false
  vim.bo[buf.bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_name, buf.bufnr, "")
  pcall(vim.api.nvim_buf_set_name, buf.bufnr, name)
  vim.api.nvim_buf_set_lines(buf.bufnr, 0, -1, false, ensure_lines(lines))
  if ft ~= "" then
    vim.bo[buf.bufnr].filetype = ft
  else
    vim.bo[buf.bufnr].filetype = "jujutsu-diff-split"
  end
  vim.bo[buf.bufnr].modifiable = false
  vim.bo[buf.bufnr].modified = false
  vim.bo[buf.bufnr].readonly = true
end

local function diffoff_wins(state)
  for _, win in ipairs({ state.left_win, state.right_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)
    end
  end
end

---Clear both sides to empty placeholders.
---@param state DiffSplit
function M.clear(state)
  if not state then return end
  diffoff_wins(state)
  set_content(state.left_buf, { "" }, state.uri_prefix .. "/a", "")
  set_content(state.right_buf, { "" }, state.uri_prefix .. "/b", "")
end

---Show a 2-way Neovim diffsplit for path between two revisions.
---@param state DiffSplit
---@param left_rev string
---@param right_rev string
---@param path string
function M.show_sides(state, left_rev, right_rev, path)
  if not state or not path or path == "" then
    M.clear(state)
    return
  end

  local left_lines = file_show(state.root, left_rev, path)
  local right_lines = file_show(state.root, right_rev, path)
  local ft = detect_filetype(path)

  diffoff_wins(state)

  set_content(state.left_buf, left_lines, state.uri_prefix .. "/a/" .. path, ft)
  set_content(state.right_buf, right_lines, state.uri_prefix .. "/b/" .. path, ft)

  if state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
    vim.api.nvim_win_call(state.left_win, function()
      vim.cmd("diffthis")
      vim.cmd("normal! gg")
    end)
  end
  if state.right_win and vim.api.nvim_win_is_valid(state.right_win) then
    vim.api.nvim_win_call(state.right_win, function()
      vim.cmd("diffthis")
      vim.cmd("normal! gg")
    end)
  end
end

---Show parent → revision 2-way diff for a path.
---@param state DiffSplit
---@param rev string
---@param path string
function M.show_file(state, rev, path) M.show_sides(state, rev .. "-", rev, path) end

---@param state DiffSplit
function M.destroy(state)
  if not state then return end
  diffoff_wins(state)
  for _, buf in ipairs({ state.left_buf, state.right_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf.bufnr) then
      vim.bo[buf.bufnr].modifiable = true
      pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    end
  end
end

return M
