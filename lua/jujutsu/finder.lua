local cli = require("jujutsu.jj.cli")
local fuzzy = require("jujutsu.buffers.fuzzy_finder")
local input_buf = require("jujutsu.buffers.input")

local M = {}

local SEP, REC = "\x1f", "\x1e"

local function field_template(fields)
  local parts = {}
  for i, f in ipairs(fields) do
    if i > 1 then
      table.insert(parts, string.format('"\\x1f" ++ %s', f))
    else
      table.insert(parts, f)
    end
  end
  return table.concat(parts, " ++ ") .. ' ++ "\\x1e"'
end

local function parse_sep_records(text)
  local entries = {}
  for rec in (text .. REC):gmatch("(.-)" .. REC) do
    if rec ~= "" then table.insert(entries, vim.split(rec:gsub("\n", ""), SEP, { plain = true })) end
  end
  return entries
end

---@class FinderPickOpts
---@field prompt? string
---@field entries? any[]
---@field allow_multi? boolean
---@field allow_free_text? boolean
---@field cwd? string
---@field refocus_status? boolean

---@class FinderInputOpts
---@field prompt? string
---@field default? string
---@field allow_empty? boolean
---@field placeholder? string

local function once_cb(cb)
  local settled = false
  return function(item)
    if settled then return end
    settled = true
    -- Let the picker finish closing / restoring windows before the caller continues.
    vim.schedule(function() cb(item) end)
  end
end

---Keep reclaiming finder/input focus for a while (status/popup teardown often steals it).
---@param target_win? integer when set, prefer this window id
---@param filetype? string
local function ensure_picker_focus(target_win, filetype)
  filetype = filetype or "jujutsu-finder"
  local deadline = vim.uv.now() + 2000
  local group = vim.api.nvim_create_augroup("JujutsuPickerFocus", { clear = true })

  local function focus_picker()
    if vim.uv.now() > deadline then
      pcall(vim.api.nvim_del_augroup_by_name, "JujutsuPickerFocus")
      return false
    end

    if target_win and vim.api.nvim_win_is_valid(target_win) then
      if vim.api.nvim_get_current_win() ~= target_win then pcall(vim.api.nvim_set_current_win, target_win) end
      pcall(vim.cmd, "redraw")
      return true
    end

    local cur = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(cur) then
      local buf = vim.api.nvim_win_get_buf(cur)
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == filetype then return true end
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == filetype then
          pcall(vim.api.nvim_set_current_win, win)
          pcall(vim.cmd, "redraw")
          return true
        end
      end
    end
    return false
  end

  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "WinNew", "WinLeave" }, {
    group = group,
    callback = function() vim.schedule(focus_picker) end,
  })

  local delay = 0
  while delay <= 2000 do
    if delay == 0 then
      vim.schedule(focus_picker)
    else
      vim.defer_fn(focus_picker, delay)
    end
    delay = delay == 0 and 10 or (delay < 100 and delay + 20 or delay + 50)
  end
  vim.defer_fn(function() pcall(vim.api.nvim_del_augroup_by_name, "JujutsuPickerFocus") end, 2100)
end

---Pick from entries using the built-in fuzzy finder.
---@param opts FinderPickOpts
---@return string|string[]|nil
function M.pick(opts)
  opts = opts or {}
  if not coroutine.running() then error("jujutsu.finder.pick must be called from async.void / a coroutine") end

  local async = require("jujutsu.async")
  return async.await(function(cb)
    -- Open on the next tick so popup/status teardown cannot race win enter.
    vim.schedule(function()
      pcall(vim.cmd, "redraw!")
      fuzzy.open({
        prompt = opts.prompt,
        entries = opts.entries,
        allow_multi = opts.allow_multi,
        allow_free_text = opts.allow_free_text,
        on_select = once_cb(cb),
        on_open = function(win) ensure_picker_focus(win, "jujutsu-finder") end,
      })
    end)
  end)
end

---Yes/No confirmation (must run inside async.void / a coroutine).
---@param prompt string
---@param opts? { yes?: string, no?: string }
---@return boolean
function M.confirm(prompt, opts)
  opts = opts or {}
  local yes = opts.yes or "Yes"
  local no = opts.no or "No"
  local choice = M.pick({ prompt = prompt, entries = { yes, no } })
  return choice == yes
end

---Prompt for a single line of free text (must run inside async.void / a coroutine).
---Returns nil when aborted; empty string when allow_empty and user confirms empty.
---@param opts FinderInputOpts
---@return string|nil
function M.input(opts)
  opts = opts or {}
  if not coroutine.running() then error("jujutsu.finder.input must be called from async.void / a coroutine") end

  local async = require("jujutsu.async")
  return async.await(function(cb)
    vim.schedule(function()
      pcall(vim.cmd, "redraw!")
      input_buf.open({
        prompt = opts.prompt,
        default = opts.default,
        allow_empty = opts.allow_empty,
        placeholder = opts.placeholder,
        on_submit = once_cb(cb),
        on_open = function(win) ensure_picker_focus(win, "jujutsu-input") end,
      })
    end)
  end)
end

---@param opts? { prompt?: string, cwd?: string }
---@return string|nil
function M.pick_revision(opts)
  opts = opts or {}
  local cwd = opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local tmpl = field_template({
    "change_id.short(8)",
    "description.first_line()",
    'bookmarks.join(",")',
  })
  local res = cli.log.revisions("all()").no_graph.template(tmpl).limit(100).call({ cwd = cwd, hidden = true })
  local entries = {}
  for _, f in ipairs(parse_sep_records(table.concat(res.stdout, "\n"))) do
    if f[1] and f[1] ~= "" then
      local bm = f[3] and f[3] ~= "" and (" [" .. f[3] .. "]") or ""
      table.insert(entries, { text = string.format("%s  %s%s", f[1], f[2] or "", bm) })
    end
  end
  local selected = M.pick({ prompt = opts.prompt or "revision", entries = entries })
  if not selected then return nil end
  return vim.split(selected, "%s+")[1]
end

---@param opts? { prompt?: string, cwd?: string, allow_free_text?: boolean, local_only?: boolean }
---@return string|nil
function M.pick_bookmark(opts)
  opts = opts or {}
  local cwd = opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local bookmark = require("jujutsu.jj.bookmark")
  local items = bookmark.list(cwd)
  local entries = {}
  local seen = {}
  local bare_names = opts.allow_free_text or opts.local_only

  for _, bm in ipairs(items) do
    local skip = bm.remote == "git" or (opts.local_only and bm.remote ~= "") or (bare_names and seen[bm.name])
    if not skip then
      if bare_names then seen[bm.name] = true end
      local name = bare_names and bm.name or (bm.remote ~= "" and (bm.name .. "@" .. bm.remote) or bm.name)
      local detail = bm.description ~= "" and bm.description or bm.change_id
      table.insert(entries, { text = string.format("%s  %s", name, detail or "") })
    end
  end

  local selected = M.pick({
    prompt = opts.prompt or "bookmark",
    entries = entries,
    allow_free_text = opts.allow_free_text,
  })
  if not selected then return nil end
  return vim.split(selected, "%s+")[1]
end

---@param opts? { prompt?: string, cwd?: string }
---@return string|nil
function M.pick_remote(opts)
  opts = opts or {}
  local cwd = opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local res = cli.git_remote_list.call({ cwd = cwd, hidden = true })
  local entries = {}
  for _, line in ipairs(res.stdout) do
    local name = line:match("^(%S+)")
    if name then table.insert(entries, line) end
  end
  local selected = M.pick({ prompt = opts.prompt or "remote", entries = entries })
  if not selected then return nil end
  return vim.split(selected, "%s+")[1]
end

---@param opts? { cwd?: string }
---@return string[]
function M.list_branches(opts)
  opts = opts or {}
  local cwd = opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local branches = {}
  local seen = {}

  local function add(name)
    name = vim.trim(name or "")
    if name == "" or seen[name] then return end
    seen[name] = true
    table.insert(branches, name)
  end

  local ok, lines = pcall(vim.fn.systemlist, {
    "git",
    "-C",
    cwd,
    "for-each-ref",
    "--format=%(refname:short)",
    "refs/heads",
  })
  if ok then
    for _, line in ipairs(lines) do
      add(line)
    end
  end

  ok, lines = pcall(vim.fn.systemlist, {
    "git",
    "-C",
    cwd,
    "for-each-ref",
    "--format=%(refname:short)",
    "refs/remotes/origin",
  })
  if ok then
    for _, line in ipairs(lines) do
      if line ~= "origin/HEAD" then add(line:match("^origin/(.+)$") or line) end
    end
  end

  return branches
end

---@param cwd? string
---@return string|nil
function M.current_branch(cwd)
  cwd = cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local ok, lines = pcall(vim.fn.systemlist, { "git", "-C", cwd, "branch", "--show-current" })
  if not ok then return nil end
  local cur = vim.trim(lines[1] or "")
  return cur ~= "" and cur or nil
end

---@param opts? { cwd?: string, remote?: ForgeRemote }
---@return string|nil
function M.default_base_branch(opts)
  opts = opts or {}
  local cwd = opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local remote = opts.remote

  if remote and remote.provider == "github" and vim.fn.executable("gh") == 1 then
    local repo = remote.owner .. "/" .. remote.repo
    local obj = vim
      .system({
        "gh",
        "repo",
        "view",
        repo,
        "--json",
        "defaultBranchRef",
        "-q",
        ".defaultBranchRef.name",
      }, { cwd = cwd, text = true })
      :wait()
    if obj.code == 0 then
      local name = vim.trim(obj.stdout or "")
      if name ~= "" then return name end
    end
  end

  local ok, sym = pcall(vim.fn.systemlist, { "git", "-C", cwd, "symbolic-ref", "refs/remotes/origin/HEAD" })
  if ok and sym[1] then
    local name = sym[1]:match("refs/remotes/origin/(.+)$")
    if name and name ~= "" then return name end
  end

  for _, candidate in ipairs({ "main", "master", "develop" }) do
    for _, branch in ipairs(M.list_branches({ cwd = cwd })) do
      if branch == candidate then return candidate end
    end
  end
  return nil
end

---@class FinderBranchOpts
---@field prompt? string
---@field cwd? string
---@field remote? ForgeRemote
---@field role? "head"|"base"
---@field default? string
---@field optional? boolean

---Pick a git branch (must run inside async.void / a coroutine).
---@param opts FinderBranchOpts
---@return string|nil nil when skipped or aborted
function M.pick_branch(opts)
  opts = opts or {}
  if not coroutine.running() then error("jujutsu.finder.pick_branch must be called from async.void / a coroutine") end

  local cwd = opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local branches = M.list_branches({ cwd = cwd })
  local default = opts.default
  if not default and opts.role == "head" then default = M.current_branch(cwd) end
  if not default and opts.role == "base" then default = M.default_base_branch({ cwd = cwd, remote = opts.remote }) end

  if #branches == 0 then
    return M.input({
      prompt = opts.prompt or "Branch",
      default = default,
      allow_empty = opts.optional == true,
      placeholder = opts.optional and "Leave empty to use default" or nil,
    })
  end

  local entries = {}
  if opts.optional then table.insert(entries, "(use default)") end

  local ordered = {}
  local seen = {}
  local function offer(name)
    if not name or name == "" or seen[name] then return end
    seen[name] = true
    table.insert(ordered, name)
  end
  offer(default)
  if opts.role == "head" then offer(M.current_branch(cwd)) end
  for _, b in ipairs(branches) do
    offer(b)
  end
  table.sort(ordered, function(a, b)
    if a == default then return true end
    if b == default then return false end
    return a < b
  end)

  for _, b in ipairs(ordered) do
    local label = b
    if b == default then label = b .. " (default)" end
    table.insert(entries, label)
  end

  local selected = M.pick({
    prompt = opts.prompt or "Branch",
    entries = entries,
    allow_free_text = true,
  })
  if not selected then return nil end
  selected = tostring(selected):gsub("%s+%(default%)$", "")
  if selected == "(use default)" then return nil end
  return selected
end

return M
