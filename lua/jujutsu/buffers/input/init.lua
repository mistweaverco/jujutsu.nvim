local M = {}

---@class InputBufferOpts
---@field prompt? string
---@field default? string
---@field allow_empty? boolean if false, Enter on empty aborts (returns nil)
---@field placeholder? string hint shown when value is empty
---@field on_submit fun(value: string|nil) nil = aborted
---@field on_open? fun(win: integer, bufnr: integer)
---@field on_refresh? fun() optional callback after forge cache refresh

---Single-line text input float, styled like the fuzzy finder.
---Typing works in normal mode (same character-map approach as the finder).
---@param opts InputBufferOpts
function M.open(opts)
  opts = opts or {}
  local cursor_mod = require("jujutsu.ui.cursor")
  cursor_mod.push_typing()
  local prompt = opts.prompt or "input"
  local allow_empty = opts.allow_empty == true
  local placeholder = opts.placeholder or (allow_empty and "Leave empty to skip" or "Type a value")
  local value = opts.default or ""
  local closed = false

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "jujutsu-input"

  local height = 5
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = vim.o.lines - height - 2,
    col = 0,
    width = vim.o.columns,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. prompt .. " ",
    title_pos = "left",
    focusable = true,
    zindex = 200,
  })
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  if type(opts.on_open) == "function" then opts.on_open(win, bufnr) end

  local function close(result)
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    cursor_mod.pop_typing()
    vim.schedule(function() opts.on_submit(result) end)
  end

  local function redraw()
    local hint = string.format(
      "<cr> confirm  <esc>/<c-c> abort  <c-r> refresh forge cache%s",
      allow_empty and "  (empty ok)" or ""
    )
    local input_line = "> " .. value .. " "
    local lines = {
      input_line,
      string.rep("─", 40),
      value == "" and ("  " .. placeholder) or "",
      "  " .. hint,
    }
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 2 + #value })
  end

  local function submit()
    local trimmed = vim.trim(value)
    if trimmed == "" then
      close(allow_empty and "" or nil)
      return
    end
    close(trimmed)
  end

  local map = function(key, fn)
    vim.keymap.set("n", key, fn, { buffer = bufnr, silent = true, nowait = true, noremap = true })
  end

  map("<cr>", submit)
  map("<c-c>", function() close(nil) end)
  map("<esc>", function() close(nil) end)
  map("q", function() close(nil) end)
  map("<bs>", function()
    value = value:sub(1, -2)
    redraw()
  end)
  map("<c-h>", function()
    value = value:sub(1, -2)
    redraw()
  end)
  map("<c-u>", function()
    value = ""
    redraw()
  end)
  map("<c-w>", function()
    value = value:gsub("%s+%S*$", ""):gsub("%S+$", "")
    redraw()
  end)
  map("<c-r>", function()
    local cache = require("jujutsu.forge.cache")
    if type(opts.on_refresh) == "function" then
      cache.with_refresh(function() opts.on_refresh() end)
    else
      cache.clear()
      require("jujutsu.notify").info("Forge cache cleared")
    end
  end)

  -- Same character set spirit as the fuzzy finder, plus a few input-friendly chars.
  local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" .. "._/@:-~^+=#,?!*()[]{}<>|;'`\"\\"
  for i = 1, #chars do
    local ch = chars:sub(i, i)
    map(ch, function()
      value = value .. ch
      redraw()
    end)
  end
  map("<space>", function()
    value = value .. " "
    redraw()
  end)

  redraw()
end

return M
