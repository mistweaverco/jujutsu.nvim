local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local mappings = require("jujutsu.ui.mappings")
local notify = require("jujutsu.notify")

local M = {}

---@class EditorOpts
---@field revision? string
---@field root? string
---@field mode? "describe"|"commit"  -- commit = describe + new
---@field on_submit? fun()
---@field on_abort? fun()
---@field initial? string
---@field apply? fun(msg: string)  -- if set, called instead of describe/commit

---@param opts EditorOpts
function M.open(opts)
  opts = opts or {}
  local root = opts.root or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local revision = opts.revision or "@"
  local mode = opts.mode or "describe"

  local current = ""
  if not opts.initial then
    local res =
      cli.log.revisions(revision).no_graph.template("description").limit(1).call({ cwd = root, hidden = true })
    if res.code == 0 then current = table.concat(res.stdout, "\n") end
  else
    current = opts.initial
  end

  local lines = vim.split(current, "\n", { plain = true })
  if #lines == 1 and lines[1] == "" then lines = { "" } end
  table.insert(lines, "")
  table.insert(lines, "# Describe the change. Save to submit, quit to abort.")
  table.insert(lines, "# Lines starting with # are ignored.")

  local buf = Buffer.create("jujutsu://describe/" .. revision, "gitcommit")
  vim.bo[buf.bufnr].buftype = "acwrite"
  vim.bo[buf.bufnr].modifiable = true
  vim.bo[buf.bufnr].bufhidden = "wipe"
  Buffer.open(buf, config.values.commit_editor.kind or "tab")
  vim.api.nvim_buf_set_lines(buf.bufnr, 0, -1, false, lines)

  if config.values.commit_editor.spell_check then vim.wo[buf.winid].spell = true end

  local submitted = false

  local function get_message()
    local all = vim.api.nvim_buf_get_lines(buf.bufnr, 0, -1, false)
    local filtered = {}
    for _, line in ipairs(all) do
      if not line:match("^#") then table.insert(filtered, line) end
    end
    return vim.trim(table.concat(filtered, "\n"))
  end

  local function submit()
    if submitted then return end
    local msg = get_message()
    if msg == "" then
      notify.warn("Empty description, aborting")
      return
    end
    submitted = true
    async.void(function()
      if opts.apply then
        opts.apply(msg)
      else
        local r = cli.describe.revision(revision).message(msg).call_async({ cwd = root, hidden = false })
        if r.code == 0 and mode == "commit" then cli.new.call_async({ cwd = root, hidden = false }) end
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf.bufnr) then vim.api.nvim_buf_delete(buf.bufnr, { force = true }) end
        if opts.on_submit then opts.on_submit() end
      end)
    end)
  end

  local function abort()
    if submitted then return end
    submitted = true
    if vim.api.nvim_buf_is_valid(buf.bufnr) then vim.api.nvim_buf_delete(buf.bufnr, { force = true }) end
    if opts.on_abort then opts.on_abort() end
  end

  mappings.apply(buf.bufnr, "commit_editor", {
    Close = abort,
    Submit = submit,
    Abort = abort,
  })
  mappings.apply(buf.bufnr, "commit_editor_I", {
    Submit = submit,
    Abort = abort,
  }, { mode = "i" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf.bufnr,
    callback = function() submit() end,
  })

  local insert = config.values.disable_insert_on_commit
  if insert == false or (insert == "auto" and vim.trim(current) == "") then vim.cmd("startinsert") end
end

return M
