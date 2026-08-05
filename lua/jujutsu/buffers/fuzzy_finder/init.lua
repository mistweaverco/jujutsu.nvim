local M = {}

---@param needle string
---@param haystack string
---@return number|nil
local function score_match(needle, haystack)
  if needle == "" then return 0 end
  needle, haystack = needle:lower(), haystack:lower()
  local ni, score, prev = 1, 0, 0
  for hi = 1, #haystack do
    if haystack:sub(hi, hi) == needle:sub(ni, ni) then
      score = score + 1
      if prev + 1 == hi then score = score + 2 end
      if hi == 1 or haystack:sub(hi - 1, hi - 1):match("[%s%p_/]") then score = score + 3 end
      prev = hi
      ni = ni + 1
      if ni > #needle then return score - (#haystack - #needle) * 0.01 end
    end
  end
  return nil
end

---@class FuzzyFinderOpts
---@field prompt? string
---@field entries string[]|{text:string}[]
---@field allow_multi? boolean
---@field allow_free_text? boolean
---@field on_select fun(item: string|string[]|nil)
---@field on_open? fun(win: integer, bufnr: integer)

---@param opts FuzzyFinderOpts
function M.open(opts)
  local cursor_mod = require("jujutsu.ui.cursor")
  cursor_mod.push_typing()
  local prompt = opts.prompt or "select"
  local allow_multi = opts.allow_multi or false
  local allow_free_text = opts.allow_free_text or false
  local entries = {}
  for _, e in ipairs(opts.entries or {}) do
    table.insert(entries, type(e) == "table" and (e.text or tostring(e[1])) or tostring(e))
  end

  local query, cursor = "", 1
  local selected = {}
  local filtered = {}
  local closed = false

  local height = math.max(10, math.floor(vim.o.lines * 0.4))
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "jujutsu-finder"

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
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  if type(opts.on_open) == "function" then opts.on_open(win, bufnr) end

  local function close(result)
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    cursor_mod.pop_typing()
    vim.schedule(function() opts.on_select(result) end)
  end

  local function refilter()
    filtered = {}
    for _, text in ipairs(entries) do
      local s = score_match(query, text)
      if s then table.insert(filtered, { text = text, score = s }) end
    end
    table.sort(filtered, function(a, b) return a.score > b.score end)
    cursor = math.max(1, math.min(cursor, #filtered))
  end

  local function redraw()
    refilter()
    local lines = { "> " .. query .. " ", string.rep("─", 40) }
    for i, item in ipairs(filtered) do
      local mark = selected[item.text] and "*" or " "
      local cur = i == cursor and ">" or " "
      table.insert(lines, string.format("%s%s %s", cur, mark, item.text))
    end
    if #filtered == 0 then
      table.insert(lines, allow_free_text and "  (no matches - Enter to use typed text)" or "  (no matches)")
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 2 + #query })
  end

  local function current() return filtered[cursor] and filtered[cursor].text end

  local function do_select()
    if allow_multi then
      local list = {}
      for t, on in pairs(selected) do
        if on then table.insert(list, t) end
      end
      if #list == 0 and current() then list = { current() } end
      close(#list > 0 and list or nil)
    else
      local value = current()
      if not value and allow_free_text then
        value = query:match("^%s*(.-)%s*$")
        if value == "" then value = nil end
      end
      close(value)
    end
  end

  local map = function(key, fn) vim.keymap.set("n", key, fn, { buffer = bufnr, silent = true, nowait = true }) end

  map("<cr>", do_select)
  map("<c-c>", function() close(nil) end)
  map("<esc>", function() close(nil) end)
  map("q", function() close(nil) end)
  map("<c-n>", function()
    cursor = math.min(cursor + 1, #filtered)
    redraw()
  end)
  map("<down>", function()
    cursor = math.min(cursor + 1, #filtered)
    redraw()
  end)
  map("j", function()
    cursor = math.min(cursor + 1, #filtered)
    redraw()
  end)
  map("<c-p>", function()
    cursor = math.max(cursor - 1, 1)
    redraw()
  end)
  map("<up>", function()
    cursor = math.max(cursor - 1, 1)
    redraw()
  end)
  map("k", function()
    cursor = math.max(cursor - 1, 1)
    redraw()
  end)
  map("<bs>", function()
    query = query:sub(1, -2)
    cursor = 1
    redraw()
  end)
  map("<c-h>", function()
    query = query:sub(1, -2)
    cursor = 1
    redraw()
  end)
  map("<c-u>", function()
    query = ""
    cursor = 1
    redraw()
  end)
  map("<space>", function()
    if allow_multi and current() then
      selected[current()] = not selected[current()]
      cursor = math.min(cursor + 1, #filtered)
      redraw()
    else
      query = query .. " "
      cursor = 1
      redraw()
    end
  end)
  map("<tab>", function()
    if current() then
      query = current()
      redraw()
    end
  end)

  -- Type to filter: map a-z, A-Z, 0-9, punctuation
  local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@:-~^"
  for i = 1, #chars do
    local ch = chars:sub(i, i)
    map(ch, function()
      query = query .. ch
      cursor = 1
      redraw()
    end)
  end

  redraw()
  -- Closing another UI (e.g. Diff popup) before open can leave focus elsewhere.
  local function reclaim()
    if closed then return end
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
      pcall(vim.api.nvim_set_current_win, win)
      pcall(vim.cmd, "redraw")
    end
  end
  reclaim()
  for _, delay in ipairs({ 10, 30, 60, 100, 180, 300, 500, 800, 1200 }) do
    vim.defer_fn(reclaim, delay)
  end
end

---@param opts { prompt?: string, entries: any[], allow_multi?: boolean, allow_free_text?: boolean }
---@return string|string[]|nil
function M.pick(opts)
  local async = require("jujutsu.async")
  local co = coroutine.running()
  if co then
    return async.await(
      function(cb)
        M.open({
          prompt = opts.prompt,
          entries = opts.entries,
          allow_multi = opts.allow_multi,
          allow_free_text = opts.allow_free_text,
          on_select = cb,
        })
      end
    )
  end
  local result, done = nil, false
  M.open({
    prompt = opts.prompt,
    entries = opts.entries,
    allow_multi = opts.allow_multi,
    allow_free_text = opts.allow_free_text,
    on_select = function(item)
      result = item
      done = true
    end,
  })
  vim.wait(1e9, function() return done end, 40)
  return result
end

return M
