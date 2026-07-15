local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local fuzzy = require("jujutsu.buffers.fuzzy_finder")

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
---@field cwd? string
---@field refocus_status? boolean

---Pick from entries using best available picker.
---@param opts FinderPickOpts
---@return string|string[]|nil
function M.pick(opts)
  opts = opts or {}
  local entries = opts.entries or {}

  -- Prefer external pickers when available
  if config.check_integration("telescope") then
    return M._telescope(opts)
  elseif config.check_integration("fzf_lua") then
    return M._fzf_lua(opts)
  elseif config.check_integration("mini_pick") then
    return M._mini_pick(opts)
  elseif config.check_integration("snacks") then
    return M._snacks(opts)
  end

  -- Built-in
  return fuzzy.pick({
    prompt = opts.prompt or "select",
    entries = entries,
    allow_multi = opts.allow_multi,
  })
end

local function to_strings(entries)
  local out = {}
  for _, e in ipairs(entries) do
    if type(e) == "table" then
      table.insert(out, e.text or tostring(e[1]))
    else
      table.insert(out, tostring(e))
    end
  end
  return out
end

function M._telescope(opts)
  local result
  local done = false
  local async = require("jujutsu.async")
  local co = coroutine.running()

  local function run(cb)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    pickers
      .new({}, {
        prompt_title = opts.prompt or "select",
        finder = finders.new_table({ results = to_strings(opts.entries or {}) }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            cb(selection and selection[1] or nil)
          end)
          return true
        end,
      })
      :find()
  end

  if co then return async.await(run) end
  run(function(item)
    result = item
    done = true
  end)
  vim.wait(1e9, function() return done end, 50)
  return result
end

function M._fzf_lua(opts)
  local result
  local done = false
  local async = require("jujutsu.async")
  local co = coroutine.running()
  local function run(cb)
    require("fzf-lua").fzf_exec(to_strings(opts.entries or {}), {
      prompt = (opts.prompt or "select") .. "> ",
      actions = {
        ["default"] = function(selected) cb(selected and selected[1] or nil) end,
      },
    })
  end
  if co then return async.await(run) end
  run(function(item)
    result = item
    done = true
  end)
  vim.wait(1e9, function() return done end, 50)
  return result
end

function M._mini_pick(opts)
  local result
  local done = false
  local async = require("jujutsu.async")
  local co = coroutine.running()
  local function run(cb)
    require("mini.pick").start({
      source = {
        items = to_strings(opts.entries or {}),
        choose = function(item) cb(item) end,
      },
    })
  end
  if co then return async.await(run) end
  run(function(item)
    result = item
    done = true
  end)
  vim.wait(1e9, function() return done end, 50)
  return result
end

function M._snacks(opts)
  local result
  local done = false
  local async = require("jujutsu.async")
  local co = coroutine.running()
  local function run(cb)
    local items = {}
    for i, text in ipairs(to_strings(opts.entries or {})) do
      items[i] = { idx = i, text = text }
    end
    require("snacks.picker").pick(nil, {
      title = opts.prompt or "select",
      items = items,
      format = "text",
      confirm = function(picker, item)
        picker:close()
        cb(item and item.text or nil)
      end,
      on_close = function() cb(nil) end,
    })
  end
  if co then return async.await(run) end
  run(function(item)
    result = item
    done = true
  end)
  vim.wait(1e9, function() return done end, 50)
  return result
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

---@param opts? { prompt?: string, cwd?: string }
---@return string|nil
function M.pick_bookmark(opts)
  opts = opts or {}
  local cwd = opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local tmpl = field_template({
    "name",
    'if(remote, remote, "")',
    "target.short(8)",
  })
  local res = cli.bookmark_list.all_remotes.template(tmpl).call({ cwd = cwd, hidden = true })
  local entries = {}
  for _, f in ipairs(parse_sep_records(table.concat(res.stdout, "\n"))) do
    if f[1] and f[1] ~= "" then
      local name = f[1]
      if f[2] and f[2] ~= "" then name = name .. "@" .. f[2] end
      table.insert(entries, { text = string.format("%s  %s", name, f[3] or "") })
    end
  end
  local selected = M.pick({ prompt = opts.prompt or "bookmark", entries = entries })
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

return M
