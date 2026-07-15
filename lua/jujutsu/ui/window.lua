local config = require("jujutsu.config")

local M = {}

---@param kind? string
---@param bufnr integer
---@return integer win
function M.open(kind, bufnr)
  kind = kind or config.values.kind or "tab"
  local win

  if kind == "tab" then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "replace" then
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "split" or kind == "split_below" then
    vim.cmd("belowright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "split_above" or kind == "split_above_all" then
    vim.cmd("aboveleft split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "split_below_all" then
    vim.cmd("botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "vsplit" then
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "floating" then
    local f = config.values.floating
    local width = f.width
    local height = f.height
    if width < 1 then width = math.floor(vim.o.columns * width) end
    if height < 1 then height = math.floor(vim.o.lines * height) end
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    win = vim.api.nvim_open_win(bufnr, true, {
      relative = f.relative or "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = f.style or "minimal",
      border = f.border or "rounded",
    })
  elseif kind == "auto" then
    if vim.api.nvim_win_get_width(0) >= 160 then return M.open("vsplit", bufnr) end
    return M.open("split", bufnr)
  else
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  end

  if config.values.disable_line_numbers then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end

  return win
end

return M
