local notify = require("jujutsu.notify")

local M = {}

---@param title string
---@param opts? { initial?: string }
---@param on_done fun(body: string|nil)
function M.prompt_comment(title, opts, on_done)
  if type(opts) == "function" then
    on_done = opts
    opts = {}
  end
  opts = opts or {}
  local initial = opts.initial or ""

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_name, buf, "jujutsu://review-comment")

  local body_lines = initial ~= "" and vim.split(initial, "\n", { plain = true }) or { "" }
  local lines = vim.list_extend(vim.deepcopy(body_lines), {
    "",
    "-- :w save  <C-c> abort",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.min(80, math.floor(vim.o.columns * 0.7))
  local height = math.min(12, math.floor(vim.o.lines * 0.4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")

  local done = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end

  local function finish(body)
    if done then return end
    done = true
    close()
    on_done(body)
  end

  local function get_body()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body_acc = {}
    for _, line in ipairs(all) do
      if not line:match("^%-%- :w ") then table.insert(body_acc, line) end
    end
    while #body_acc > 0 and body_acc[#body_acc]:match("^%s*$") do
      table.remove(body_acc)
    end
    return table.concat(body_acc, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.cmd("stopinsert")
      local body = get_body()
      if body == "" then
        finish(nil)
        return
      end
      finish(body)
    end,
  })

  local map_opts = { buffer = buf, silent = true, noremap = true }
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    vim.cmd("stopinsert")
    finish(nil)
  end, map_opts)
end

---@param events string[]
---@param on_done fun(event: string|nil)
function M.pick_submit_event(events, on_done)
  local labels = {}
  local map = {}
  for _, e in ipairs(events) do
    local label = e
    if e == "COMMENT" then
      label = "Comment"
    elseif e == "APPROVE" then
      label = "Approve"
    elseif e == "REQUEST_CHANGES" then
      label = "Request changes"
    elseif e == "DRAFT" then
      label = "Draft (GitHub pending)"
    end
    table.insert(labels, label)
    map[label] = e
  end
  vim.ui.select(labels, { prompt = "Submit review as" }, function(choice)
    if not choice then
      on_done(nil)
      return
    end
    on_done(map[choice])
  end)
end

---@param text string
function M.help(text)
  local lines = vim.split(text, "\n", { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.min(60, math.floor(vim.o.columns * 0.6))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Review help ",
    title_pos = "center",
  })
  local close = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<esc>", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "?", close, { buffer = buf, silent = true })
end

function M.copy_markdown(md)
  vim.fn.setreg("+", md)
  vim.fn.setreg('"', md)
  notify.info("Review copied to clipboard")
end

return M
