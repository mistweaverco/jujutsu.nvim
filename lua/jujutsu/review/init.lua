local DiffBuffer = require("jujutsu.buffers.diff")
local async = require("jujutsu.async")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local remote_mod = require("jujutsu.forge.remote")
local session_mod = require("jujutsu.review.session")

local M = {}

---@param root string
---@param sha string
---@return string
local function resolve_rev(root, sha)
  if not sha or sha == "" then return sha end
  -- Prefer full commit id if jj can see it
  local res = cli.log.revisions(sha).no_graph.template("commit_id").limit(1).call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if res.code == 0 and res.stdout and res.stdout[1] and res.stdout[1] ~= "" then return res.stdout[1] end
  return sha
end

---@param root string
---@param pr table
---@param rem ForgeRemote
local function open_session(root, pr, rem)
  local left = resolve_rev(root, pr.base_sha)
  local right = resolve_rev(root, pr.head_sha)
  if not left or left == "" then left = pr.base_ref ~= "" and pr.base_ref or "trunk()" end
  if not right or right == "" then right = pr.head_ref ~= "" and pr.head_ref or "@" end

  local session = session_mod.create({
    root = root,
    remote = rem,
    pr = pr,
    left_rev = left,
    right_rev = right,
    title = string.format("#%s %s", tostring(pr.number), pr.title or ""),
  })

  notify.info("Loading existing review comments…")
  session.remote_comments = provider.list_review_comments(root, pr.number, rem)
  if #session.remote_comments > 0 then
    notify.info(string.format("Loaded %d remote comment(s)", #session.remote_comments))
  end

  DiffBuffer.open({
    cwd = root,
    title = session.title,
    left = left,
    right = right,
    builder = cli.diff.from(left).to(right),
    review = session,
  })
end

---Run review continuation inside a coroutine so finder.pick can await
---instead of vim.wait (which freezes picker input / redraw).
---@param fn function
local function run_async(fn)
  vim.schedule(function() async.void(fn) end)
end

---@param root string
---@param rem ForgeRemote
---@param opts { number?: integer|string }
local function continue_open(root, rem, opts)
  local function start(pr)
    if not pr then return end
    open_session(root, pr, rem)
  end

  local function on_auth_err(err, retry)
    if not provider.is_auth_error(err) then return false end
    notify.error(err or "Authentication failed")
    provider.handle_auth_failure(rem, function(updated)
      if updated then run_async(retry) end
    end)
    return true
  end

  if opts.number then
    local function load_number()
      local pr, err = provider.get_pr(root, opts.number, rem)
      if not pr then
        if on_auth_err(err, load_number) then return end
        notify.error(err or "Failed to load PR")
        return
      end
      start(pr)
    end
    load_number()
    return
  end

  local function load_list()
    local list, err = provider.list_prs(root, rem)
    if err then
      if on_auth_err(err, load_list) then return end
      notify.error(err)
      return
    end
    if #list == 0 then
      notify.warn("No open pull requests found")
      return
    end

    local entries = {}
    for _, pr in ipairs(list) do
      table.insert(entries, {
        text = string.format("#%s  %s  [%s]", tostring(pr.number), pr.title or "", pr.head_ref or ""),
        pr = pr,
      })
    end

    local selected = finder.pick({
      prompt = "Review PR/MR",
      entries = entries,
    })
    if not selected then return end

    local number = selected:match("^#(%d+)")
    if not number then
      notify.warn("Could not parse PR number")
      return
    end
    local pr, gerr = provider.get_pr(root, number, rem)
    if not pr then
      if on_auth_err(gerr, load_list) then return end
      -- fall back to list entry
      for _, e in ipairs(list) do
        if tostring(e.number) == tostring(number) then
          pr = e
          break
        end
      end
    end
    if not pr then
      notify.error(gerr or "Failed to load PR")
      return
    end
    start(pr)
  end

  load_list()
end

---@param opts? { cwd?: string, number?: integer|string, root?: string }
function M.open(opts)
  opts = opts or {}
  if config.values.forge.review and config.values.forge.review.enabled == false then
    notify.warn("PR review is disabled (forge.review.enabled = false)")
    return
  end

  local root = opts.root or opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local rem = remote_mod.detect(root)
  if not rem then
    notify.error("Could not detect forge remote (origin)")
    return
  end

  local function proceed()
    run_async(function() continue_open(root, rem, opts) end)
  end

  if rem.provider == "bitbucket" or rem.provider == "forgejo" then
    if not provider.transport_available(rem) then
      notify.error("curl is required for " .. rem.provider .. " reviews")
      return
    end
    provider.ensure_auth(rem, function(ok)
      if not ok then return end
      proceed()
    end)
    return
  end

  if not provider.available(rem) then
    local hints = {
      github = "Install and authenticate `gh`",
      gitlab = "Install and authenticate `glab`",
    }
    notify.error("Forge provider not available: " .. (hints[rem.provider] or rem.provider))
    return
  end

  proceed()
end

return M
