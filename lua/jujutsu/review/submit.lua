local async = require("jujutsu.async")
local comments_mod = require("jujutsu.review.comments")
local finder = require("jujutsu.finder")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local session_mod = require("jujutsu.review.session")
local ui = require("jujutsu.review.ui")

local M = {}

---@param session ReviewSession
---@param event string
---@param opts? { comments?: table[], body?: string|nil }
---@return boolean, string|nil, { posted_comments?: boolean }|nil
function M.submit(session, event, opts)
  if not session.remote or not session.number then return false, "No pull request attached to this review session" end
  opts = opts or {}
  local inline = opts.comments or comments_mod.to_provider_comments(session.comments)
  local body = opts.body
  if body == nil then body = comments_mod.review_body(session.comments) end
  local ok, err, meta = provider.submit_review(session.root, session.number, {
    event = event,
    body = body,
    commit_id = session.pr and session.pr.head_sha or session.right_rev,
    comments = inline,
  }, session.remote)
  -- Comments may already be on the forge even when approve/request-changes fails.
  if ok or (meta and meta.posted_comments) then session_mod.mark_submitted(session) end
  return ok, err, meta
end

---@param session ReviewSession
---@param event string
---@param on_done? fun(ok: boolean)
---@param opts? { comments?: table[], body?: string|nil }
local function submit_with_auth_retry(session, event, on_done, opts)
  local ok, err, meta = M.submit(session, event, opts)
  if ok then
    notify.info("Review submitted (" .. event .. ")")
    if on_done then on_done(true) end
    return
  end

  local partial = meta and meta.posted_comments
  if partial then notify.warn(err or "Comments posted, but review status change failed") end

  -- 401, or Bitbucket 403 "missing privilege scopes", → offer credential update.
  if session.remote and provider.is_auth_error(err) then
    if not partial then notify.error(err or "Authentication failed") end
    provider.handle_auth_failure(session.remote, function(updated)
      if updated then
        vim.schedule(function()
          async.void(function()
            -- Local comments were cleared on partial success; retry status only.
            if partial then
              local ok2, err2 = M.submit(session, event, { comments = {}, body = "" })
              if ok2 then
                notify.info("Review submitted (" .. event .. ")")
                if on_done then on_done(true) end
                return
              end
              notify.error(err2 or "Submit failed")
              if on_done then on_done(false) end
              return
            end
            submit_with_auth_retry(session, event, on_done, opts)
          end)
        end)
        return
      end
      if on_done then on_done(false) end
    end)
    return
  end

  if not partial then notify.error(err or "Submit failed") end
  if on_done then on_done(false) end
end

---@param events string[]
---@return string|nil event
local function pick_event(events)
  local entries = {}
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
    table.insert(entries, label)
    map[label] = e
  end
  local choice = finder.pick({
    prompt = "Submit review as",
    entries = entries,
  })
  if not choice then return nil end
  return map[tostring(choice)]
end

---@param session ReviewSession
---@param on_done? fun(ok: boolean)
function M.pick_and_submit(session, on_done)
  if not session.remote or not session.number then
    notify.warn("This review is local-only; use y to copy markdown")
    if on_done then on_done(false) end
    return
  end

  -- Re-submit is allowed after a prior submit (approve again, add a comment, …).
  -- Always schedule a fresh coroutine so the picker can await without freezing.
  vim.schedule(function()
    async.void(function()
      local event = pick_event(provider.submit_events(session.remote))
      if not event then
        if on_done then on_done(false) end
        return
      end

      local inline = comments_mod.to_provider_comments(session.comments)
      local body = comments_mod.review_body(session.comments)
      local function run(submit_opts) submit_with_auth_retry(session, event, on_done, submit_opts) end

      -- Approve / request-changes / draft are valid with an empty queue.
      -- A bare "Comment" submit still needs a message when nothing is queued.
      if event == "COMMENT" and #inline == 0 and (not body or body == "") then
        local text = async.await(function(cb) ui.prompt_comment("Review comment", {}, cb) end)
        if not text or text == "" then
          notify.warn("Add a message, or queue line/file comments first")
          if on_done then on_done(false) end
          return
        end
        run({ comments = {}, body = text })
        return
      end

      run(nil)
    end)
  end)
end

return M
