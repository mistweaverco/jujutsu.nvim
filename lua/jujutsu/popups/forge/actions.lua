local async = require("jujutsu.async")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local remote_mod = require("jujutsu.forge.remote")

local M = {}

---@param fn function
local function run_async(fn)
  vim.schedule(function() async.void(fn) end)
end

---@param popup table
---@return string, ForgeRemote|nil
local function root_remote(popup)
  local root = common.root(popup)
  return root, provider.remote(root)
end

---@param rem ForgeRemote
---@param cb fun()
local function with_auth(rem, cb)
  if rem.provider == "bitbucket" or rem.provider == "forgejo" then
    provider.ensure_auth(rem, function(ok)
      if ok then vim.schedule(cb) end
    end)
  else
    cb()
  end
end

---@param rem ForgeRemote
---@param err string|nil
---@param retry fun()
---@return boolean
local function on_auth_err(rem, err, retry)
  if not provider.is_auth_error(err) then return false end
  notify.error(err or "Authentication failed")
  provider.handle_auth_failure(rem, function(updated)
    if updated then run_async(retry) end
  end)
  return true
end

---@param popup table
local function close_popup(popup)
  if popup and popup.close then popup:close() end
end

---@param item table
---@return string
local function topic_entry_text(item)
  local draft = item.draft and " [draft]" or ""
  local state = item.state and (" (" .. tostring(item.state) .. ")") or ""
  local ref = item.head_ref and item.head_ref ~= "" and (" [" .. item.head_ref .. "]") or ""
  return string.format("#%s  %s%s%s%s", tostring(item.number), item.title or "", draft, state, ref)
end

---@param texts string[]
---@return { text: string }[]
local function as_entries(texts)
  local out = {}
  for _, t in ipairs(texts) do
    table.insert(out, { text = t })
  end
  return out
end

---Pick from a fixed list (must run inside async.void).
---@param prompt string
---@param choices string[]
---@return string|nil
local function pick_choice(prompt, choices)
  pcall(vim.cmd, "redraw!")
  if coroutine.running() then async.sleep(30) end
  return finder.pick({ prompt = prompt, entries = as_entries(choices) })
end

---Free-text input. Optional empty confirms as skip (nil).
---@param prompt string
---@param opts? { default?: string, optional?: boolean, placeholder?: string }
---@return string|nil
local function pick_text(prompt, opts)
  opts = opts or {}
  pcall(vim.cmd, "redraw!")
  if coroutine.running() then async.sleep(30) end
  local value = finder.input({
    prompt = prompt,
    default = opts.default,
    allow_empty = opts.optional == true,
    placeholder = opts.placeholder or (opts.optional and "Leave empty to skip" or nil),
  })
  if value == nil then return nil end -- aborted
  if opts.optional and value == "" then return nil end
  return value
end

---Collect search filters: lists via picker, free text via input.
---@param defaults? ForgeSearchFilter
---@return ForgeSearchFilter|nil
local function collect_filters(defaults)
  local result = vim.deepcopy(defaults or {})
  local state = pick_choice("State", { "open", "closed", "all", "merged" })
  if not state then return nil end
  result.state = state

  local own = pick_choice("Ownership", { "anyone", "assigned to me", "authored by me" })
  if not own then return nil end
  if own == "assigned to me" then
    result.assignee = "@me"
  elseif own == "authored by me" then
    result.author = "@me"
  end

  local label = pick_text("Label filter", { optional = true })
  if label then result.label = label end

  local query = pick_text("Search query", { optional = true })
  if query then result.query = query end

  return result
end

function M.review(popup)
  local root = common.root(popup)
  close_popup(popup)
  vim.schedule(function()
    pcall(vim.cmd, "redraw!")
    require("jujutsu.review").open({ root = root })
  end)
end

function M.browse_prs(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  close_popup(popup)
  with_auth(rem, function()
    run_async(function()
      local filter = collect_filters({ state = "open" })
      if not filter then return end
      local function load()
        local list, err = provider.search_prs(root, filter, rem)
        if err then
          if on_auth_err(rem, err, load) then return end
          notify.error(err)
          return
        end
        if #list == 0 then
          notify.warn("No pull requests found")
          return
        end
        local entries = {}
        for _, pr in ipairs(list) do
          table.insert(entries, { text = topic_entry_text(pr), item = pr })
        end
        local selected = finder.pick({ prompt = "Pull requests", entries = entries })
        if not selected then return end
        local number = selected:match("^#(%d+)")
        if not number then return end
        require("jujutsu.issue_panel").open({ root = root, remote = rem, number = number, kind = "pr" })
      end
      load()
    end)
  end)
end

function M.create_pr(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  local caps = provider.capabilities(rem)
  if not caps.prs.create then
    notify.warn("Creating PRs is not supported for " .. rem.provider)
    return
  end
  close_popup(popup)
  with_auth(rem, function()
    run_async(function()
      local title = pick_text("PR title")
      if not title then return end
      -- Hand off to markdown float; resume forge picks after :w.
      vim.schedule(function()
        require("jujutsu.review.ui").prompt_comment("PR body", {}, function(body)
          run_async(function()
            local head = pick_text("Head branch", { optional = true })
            local base = pick_text("Base branch", { optional = true })
            local draft = false
            if caps.prs.draft then
              local choice = pick_choice("PR type", { "Ready", "Draft" })
              if not choice then return end
              draft = choice == "Draft"
            end

            local function do_create()
              local pr, err = provider.create_pr(root, {
                title = title,
                body = body or "",
                head = head,
                base = base,
                draft = draft,
              }, rem)
              if not pr then
                if on_auth_err(rem, err, do_create) then return end
                notify.error(err or "Failed to create PR")
                return
              end
              notify.info(string.format("Created PR #%s", tostring(pr.number or "?")))
              if pr.number then
                require("jujutsu.issue_panel").open({
                  root = root,
                  remote = rem,
                  number = pr.number,
                  kind = "pr",
                })
              end
            end
            do_create()
          end)
        end)
      end)
    end)
  end)
end

function M.open_pr(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  close_popup(popup)
  run_async(function()
    local num = pick_text("PR/MR number")
    if not num then return end
    require("jujutsu.issue_panel").open({
      root = root,
      remote = rem,
      number = num,
      kind = "pr",
    })
  end)
end

function M.browse_issues(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  close_popup(popup)
  with_auth(rem, function()
    run_async(function()
      local filter = collect_filters({ state = "open" })
      if not filter then return end
      local function load()
        local list, err = provider.search_issues(root, filter, rem)
        if err then
          if on_auth_err(rem, err, load) then return end
          notify.error(err)
          return
        end
        if #list == 0 then
          notify.warn("No issues found")
          return
        end
        local entries = {}
        for _, issue in ipairs(list) do
          table.insert(entries, { text = topic_entry_text(issue), item = issue })
        end
        local selected = finder.pick({ prompt = "Issues", entries = entries })
        if not selected then return end
        local number = selected:match("^#(%d+)")
        if not number then return end
        require("jujutsu.issue_panel").open({ root = root, remote = rem, number = number, kind = "issue" })
      end
      load()
    end)
  end)
end

function M.create_issue(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  local caps = provider.capabilities(rem)
  if not caps.issues.create then
    notify.warn("Creating issues is not supported for " .. rem.provider)
    return
  end
  close_popup(popup)
  with_auth(rem, function()
    run_async(function()
      local title = pick_text("Issue title")
      if not title then return end
      vim.schedule(function()
        require("jujutsu.review.ui").prompt_comment("Issue body", {}, function(body)
          run_async(function()
            local issue, err = provider.create_issue(root, {
              title = title,
              body = body or "",
            }, rem)
            if not issue then
              notify.error(err or "Failed to create issue")
              return
            end
            notify.info(string.format("Created issue #%s", tostring(issue.number or "?")))
            if issue.number then
              require("jujutsu.issue_panel").open({
                root = root,
                remote = rem,
                number = issue.number,
                kind = "issue",
              })
            end
          end)
        end)
      end)
    end)
  end)
end

function M.open_issue(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  close_popup(popup)
  require("jujutsu.issue_panel").open({ root = root, remote = rem })
end

function M.list_ci(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  close_popup(popup)
  with_auth(rem, function()
    run_async(function()
      local function load()
        local runs, err = provider.list_ci_runs(root, {}, rem)
        if err then
          if on_auth_err(rem, err, load) then return end
          notify.error(err)
          return
        end
        if #runs == 0 then
          notify.warn("No CI runs found")
          return
        end
        local entries = {}
        for _, run in ipairs(runs) do
          local concl = run.conclusion and ("/" .. run.conclusion) or ""
          local cancel = run.can_cancel and " [cancellable]" or ""
          table.insert(entries, {
            text = string.format("%s  %s%s%s", run.name or run.id, run.status or "?", concl, cancel),
            run = run,
          })
        end
        local selected = finder.pick({ prompt = "CI runs", entries = entries })
        if not selected then return end
        local run
        for _, e in ipairs(entries) do
          if e.text == selected then
            run = e.run
            break
          end
        end
        if not run then return end
        local actions = { "Open in browser" }
        if run.can_cancel then table.insert(actions, "Cancel") end
        local choice = pick_choice("CI action", actions)
        if choice == "Open in browser" and run.url then
          remote_mod.open_url(run.url)
        elseif choice == "Cancel" then
          local ok, cerr = provider.cancel_ci_run(root, run.id, rem)
          if not ok then
            notify.error(cerr or "Failed to cancel")
            return
          end
          notify.info("CI run cancelled")
        end
      end
      load()
    end)
  end)
end

function M.trigger_ci(popup)
  local root, rem = root_remote(popup)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end
  close_popup(popup)
  with_auth(rem, function()
    run_async(function()
      local workflows, err = provider.list_triggerable_workflows(root, rem)
      if err then
        notify.error(err)
        return
      end
      if #workflows == 0 then
        notify.warn("No triggerable workflows")
        return
      end
      local entries = {}
      for _, w in ipairs(workflows) do
        table.insert(entries, { text = w.name or tostring(w.id), workflow = w })
      end
      local selected = finder.pick({ prompt = "Trigger workflow", entries = entries })
      if not selected then return end
      local workflow
      for _, e in ipairs(entries) do
        if e.text == selected then
          workflow = e.workflow
          break
        end
      end
      if not workflow then return end
      local ref = pick_text("Ref / branch", { default = "main" }) or "main"
      local ok, terr = provider.trigger_ci(root, {
        workflow_id = workflow.id,
        ref = ref,
      }, rem)
      if not ok then
        notify.error(terr or "Failed to trigger CI")
        return
      end
      notify.info("CI triggered")
    end)
  end)
end

return M
