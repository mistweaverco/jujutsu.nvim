local comments_mod = require("jujutsu.review.comments")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local session_mod = require("jujutsu.review.session")
local ui = require("jujutsu.review.ui")

local M = {}

---@param session ReviewSession
---@param event string
---@return boolean, string|nil
function M.submit(session, event)
  if not session.remote or not session.number then return false, "No pull request attached to this review session" end
  local inline = comments_mod.to_provider_comments(session.comments)
  local body = comments_mod.review_body(session.comments)
  local ok, err = provider.submit_review(session.root, session.number, {
    event = event,
    body = body,
    commit_id = session.pr and session.pr.head_sha or session.right_rev,
    comments = inline,
  }, session.remote)
  if not ok then return false, err end
  session_mod.mark_submitted(session)
  return true
end

---@param session ReviewSession
---@param event string
---@param on_done? fun(ok: boolean)
local function submit_with_auth_retry(session, event, on_done)
  local ok, err = M.submit(session, event)
  if ok then
    notify.info("Review submitted (" .. event .. ")")
    if on_done then on_done(true) end
    return
  end
  if session.remote and provider.is_auth_error(err) then
    notify.error(err or "Authentication failed")
    provider.handle_auth_failure(session.remote, function(updated)
      if updated then
        vim.schedule(function()
          require("jujutsu.async").void(function() submit_with_auth_retry(session, event, on_done) end)
        end)
        return
      end
      if on_done then on_done(false) end
    end)
    return
  end
  notify.error(err or "Submit failed")
  if on_done then on_done(false) end
end

---@param session ReviewSession
---@param on_done? fun(ok: boolean)
function M.pick_and_submit(session, on_done)
  if not session.remote or not session.number then
    notify.warn("This review is local-only; use y to copy markdown")
    if on_done then on_done(false) end
    return
  end
  local events = provider.submit_events(session.remote)
  ui.pick_submit_event(events, function(event)
    if not event then
      if on_done then on_done(false) end
      return
    end
    if #session.comments == 0 and event ~= "APPROVE" and event ~= "COMMENT" and event ~= "DRAFT" then
      notify.warn("No comments to submit")
      if on_done then on_done(false) end
      return
    end
    submit_with_auth_retry(session, event, on_done)
  end)
end

return M
