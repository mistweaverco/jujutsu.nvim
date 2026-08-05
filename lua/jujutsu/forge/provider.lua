local bitbucket = require("jujutsu.forge.bitbucket")
local credentials = require("jujutsu.forge.credentials")
local forgejo = require("jujutsu.forge.forgejo")
local github = require("jujutsu.forge.github")
local gitlab = require("jujutsu.forge.gitlab")
local labels_mod = require("jujutsu.forge.labels")
local remote_mod = require("jujutsu.forge.remote")

local M = {}

---@class ForgeCapabilities
---@field prs { list: boolean, search: boolean, create: boolean, update: boolean, close: boolean, merge: boolean, draft: boolean, labels: boolean }
---@field issues { list: boolean, search: boolean, create: boolean, update: boolean, close: boolean, labels: boolean }
---@field comments { list: boolean, create: boolean, update: boolean, delete: boolean }
---@field ci { list: boolean, cancel: boolean, trigger: boolean, view: boolean, logs: boolean }

---@class ForgeSearchFilter
---@field state? string "open"|"closed"|"all"|"merged"
---@field assignee? string "@me" or login
---@field author? string "@me" or login
---@field draft? boolean
---@field label? string
---@field query? string
---@field limit? integer

---@class ForgeCiRun
---@field id string
---@field name string
---@field title? string
---@field workflow? string
---@field event? string
---@field status string
---@field conclusion? string
---@field url? string
---@field can_cancel? boolean
---@field branch? string
---@field head_sha? string
---@field created_at? string
---@field updated_at? string
---@field started_at? string
---@field elapsed? string

---@class ForgeCiStep
---@field name string
---@field status string
---@field conclusion? string
---@field number? integer

---@class ForgeCiJob
---@field id string
---@field name string
---@field status string
---@field conclusion? string
---@field url? string
---@field elapsed? string
---@field started_at? string
---@field completed_at? string
---@field steps? ForgeCiStep[]

---@class ForgeCiAnnotation
---@field level? string "warning"|"error"|"notice"
---@field message string
---@field context? string

---@class ForgeCiRunDetail
---@field run ForgeCiRun
---@field jobs ForgeCiJob[]
---@field annotations? ForgeCiAnnotation[]

---@class ForgeCiJobDetail
---@field run ForgeCiRun
---@field job ForgeCiJob
---@field annotations? ForgeCiAnnotation[]

---@class ForgeWorkflow
---@field id string
---@field name string
---@field path? string
---@field can_dispatch? boolean

---@param root string
---@return ForgeRemote|nil
function M.remote(root) return remote_mod.detect(root) end

---@param remote ForgeRemote|nil
---@return table|nil module
local function backend(remote)
  if not remote then return nil end
  if remote.provider == "github" then return github end
  if remote.provider == "gitlab" then return gitlab end
  if remote.provider == "bitbucket" then return bitbucket end
  if remote.provider == "forgejo" then return forgejo end
  return nil
end

---@return ForgeCapabilities
local function empty_caps()
  return {
    prs = {
      list = false,
      search = false,
      create = false,
      update = false,
      close = false,
      merge = false,
      draft = false,
      labels = false,
    },
    issues = {
      list = false,
      search = false,
      create = false,
      update = false,
      close = false,
      labels = false,
    },
    comments = { list = false, create = false, update = false, delete = false },
    ci = { list = false, cancel = false, trigger = false, view = false, logs = false },
  }
end

---@param remote ForgeRemote|nil
---@return ForgeCapabilities
function M.capabilities(remote)
  local caps = empty_caps()
  local mod = backend(remote)
  if not mod or not remote then return caps end
  if type(mod.capabilities) == "function" then
    local got = mod.capabilities(remote)
    if type(got) == "table" then return vim.tbl_deep_extend("force", caps, got) end
  end
  -- Fallback: infer from existing methods
  caps.prs.list = type(mod.list_prs) == "function"
  caps.comments.list = type(mod.list_comments) == "function"
  caps.comments.create = type(mod.post_comment) == "function"
  return caps
end

---@param remote ForgeRemote|nil
---@return boolean
function M.available(remote)
  local mod = backend(remote)
  if not mod then return false end
  if remote and (remote.provider == "bitbucket" or remote.provider == "forgejo") then return mod.available(remote) end
  return mod.available()
end

---True when the provider can reach the forge once credentials exist (curl/gh/glab).
---@param remote ForgeRemote|nil
---@return boolean
function M.transport_available(remote)
  local mod = backend(remote)
  if not mod then return false end
  if remote and remote.provider == "bitbucket" then return vim.fn.executable("curl") == 1 end
  if remote and remote.provider == "forgejo" then return vim.fn.executable("curl") == 1 end
  return mod.available()
end

---Prompt/store credentials when missing for Bitbucket / Forgejo.
---@param remote ForgeRemote
---@param cb fun(ok: boolean)
function M.ensure_auth(remote, cb)
  if not remote then
    cb(false)
    return
  end
  if remote.provider ~= "bitbucket" and remote.provider ~= "forgejo" then
    cb(M.available(remote))
    return
  end
  if not M.transport_available(remote) then
    cb(false)
    return
  end
  credentials.ensure(remote, cb)
end

---Offer update/delete after an auth failure; cb(true) if credentials were updated.
---@param remote ForgeRemote
---@param cb fun(retried: boolean)
function M.handle_auth_failure(remote, cb)
  credentials.handle_invalid(remote, function(action) cb(action == "updated") end)
end

---@param err string|nil
---@return boolean
function M.is_auth_error(err) return credentials.is_auth_error(err) end

---@param err string|nil
---@return boolean
function M.is_scope_error(err) return credentials.is_scope_error(err) end

---@param labels ForgeLabel[]|string[]|nil
---@return string[]
function M.label_names(labels) return labels_mod.names(labels) end

---@param root string
---@param remote? ForgeRemote
-- luacheck: ignore 631
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[], string|nil
function M.list_prs(root, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {}, "No forge provider for this repository" end
  if remote.provider == "github" then return mod.list_prs(root), nil end
  return mod.list_prs(root, remote)
end

---@param root string
---@param number integer|string
---@param remote? ForgeRemote
---@return table|nil, string|nil
function M.get_pr(root, number, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return nil, "No forge provider for this repository" end
  if remote.provider == "github" then return mod.get_pr(root, number) end
  return mod.get_pr(root, remote, number)
end

---@param root string
---@param number integer|string
---@param remote? ForgeRemote
---@return boolean, string|nil, { posted_comments?: boolean }|nil
function M.submit_review(root, number, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if remote.provider == "github" then return mod.submit_review(root, remote, number, opts) end
  return mod.submit_review(root, remote, number, opts)
end

---@param root string
---@param number integer|string
---@param remote? ForgeRemote
---@return ForgeRemoteComment[]
function M.list_review_comments(root, number, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote or not mod.list_review_comments then return {} end
  if remote.provider == "github" then return mod.list_review_comments(root, remote, number) end
  return mod.list_review_comments(root, remote, number)
end

---Reply to an inline review comment / discussion (forge-specific).
---@param root string
---@param number integer|string
---@param opts { parent_id?: string|integer, discussion_id?: string, body: string }
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.post_reply(root, number, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if not mod.post_reply then return false, "Threaded replies not supported for " .. remote.provider end
  return mod.post_reply(root, remote, number, opts or {})
end

---@param remote ForgeRemote|nil
---@return boolean
function M.supports_reply(remote)
  local mod = backend(remote)
  return mod ~= nil and type(mod.post_reply) == "function"
end

---@param remote ForgeRemote|nil
---@return string[]
function M.submit_events(remote)
  if not remote then return { "COMMENT" } end
  if remote.provider == "github" then return { "COMMENT", "APPROVE", "REQUEST_CHANGES", "DRAFT" } end
  return { "COMMENT", "APPROVE", "REQUEST_CHANGES" }
end

---@class ForgeRemoteComment
---@field id string
---@field path string
---@field side "LEFT"|"RIGHT"
---@field line integer
---@field start_line? integer
---@field body string
---@field author string
---@field outdated? boolean
---@field url? string
---@field remote true
---@field parent_id? string
---@field discussion_id? string
---@field provider? string
---@field created_at? string
---@field updated_at? string
---@field supports_reply? boolean

---@class ForgeTopic
---@field kind "issue"|"pr"
---@field number integer|string
---@field title string
---@field body string
---@field state string
---@field draft? boolean
---@field merged? boolean
---@field author string
---@field created_at? string
---@field updated_at? string
---@field labels ForgeLabel[]
---@field assignees string[]
---@field url string
---@field repo string

---@class ForgeConversationComment
---@field id string
---@field author string
---@field author_association? string
---@field created_at? string
---@field updated_at? string
---@field body string
---@field url? string
---@field kind? "comment"|"review"

---@param root string
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@param remote? ForgeRemote
---@return ForgeTopic|nil, string|nil
function M.get_topic(root, number, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return nil, "No forge provider for this repository" end
  if not mod.get_topic then return nil, "Issue/PR details not supported for " .. remote.provider end
  local topic, err = mod.get_topic(root, remote, number, opts or {})
  if topic then topic.labels = labels_mod.normalize(topic.labels) end
  return topic, err
end

---@param root string
---@param number integer|string
---@param opts? { kind?: "issue"|"pr" }
---@param remote? ForgeRemote
---@return ForgeConversationComment[], string|nil
function M.list_comments(root, number, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote or not mod.list_comments then return {}, "Conversation not supported for this forge" end
  return mod.list_comments(root, remote, number, opts or {})
end

---@param root string
---@param number integer|string
---@param body string
---@param opts? { kind?: "issue"|"pr" }
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.post_comment(root, number, body, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if not mod.post_comment then return false, "Posting comments not supported for " .. remote.provider end
  return mod.post_comment(root, remote, number, body, opts or {})
end

---Call an optional adapter method with consistent (root, remote, ...) args.
---@param remote ForgeRemote|nil
---@param name string
---@param root string
---@param ... any
---@return any ...
local function call_opt(remote, name, root, ...)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return nil, "No forge provider for this repository" end
  if type(mod[name]) ~= "function" then return nil, name .. " not supported for " .. remote.provider end
  return mod[name](root, remote, ...)
end

---@param root string
---@param filter? ForgeSearchFilter
---@param remote? ForgeRemote
---@return table[], string|nil
function M.search_prs(root, filter, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {}, "No forge provider for this repository" end
  if type(mod.search_prs) ~= "function" then
    local list, err = M.list_prs(root, remote)
    return list, err
  end
  return mod.search_prs(root, remote, filter or {})
end

---@param root string
---@param opts table
---@param remote? ForgeRemote
---@return table|nil, string|nil
function M.create_pr(root, opts, remote) return call_opt(remote, "create_pr", root, opts or {}) end

---@param root string
---@param number integer|string
---@param opts table
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.update_pr(root, number, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.update_pr) ~= "function" then return false, "update_pr not supported for " .. remote.provider end
  return mod.update_pr(root, remote, number, opts or {})
end

---@param root string
---@param number integer|string
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.close_pr(root, number, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.close_pr) ~= "function" then return false, "close_pr not supported for " .. remote.provider end
  return mod.close_pr(root, remote, number)
end

---@param root string
---@param number integer|string
---@param opts? { method?: string }
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.merge_pr(root, number, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.merge_pr) ~= "function" then return false, "merge_pr not supported for " .. remote.provider end
  return mod.merge_pr(root, remote, number, opts or {})
end

---@param root string
---@param remote? ForgeRemote
---@return ForgeLabel[], string|nil
function M.list_repo_labels(root, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {}, "No forge provider for this repository" end
  if type(mod.list_repo_labels) ~= "function" then return {}, nil end
  local list, err = mod.list_repo_labels(root, remote)
  return labels_mod.normalize(list or {}), err
end

---@param root string
---@param filter? ForgeSearchFilter
---@param remote? ForgeRemote
---@return table[], string|nil
function M.search_issues(root, filter, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {}, "No forge provider for this repository" end
  if type(mod.search_issues) ~= "function" then return {}, "search_issues not supported for " .. remote.provider end
  return mod.search_issues(root, remote, filter or {})
end

---@param root string
---@param opts table
---@param remote? ForgeRemote
---@return table|nil, string|nil
function M.create_issue(root, opts, remote) return call_opt(remote, "create_issue", root, opts or {}) end

---@param root string
---@param number integer|string
---@param opts table
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.update_issue(root, number, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.update_issue) ~= "function" then return false, "update_issue not supported for " .. remote.provider end
  return mod.update_issue(root, remote, number, opts or {})
end

---@param root string
---@param number integer|string
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.close_issue(root, number, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.close_issue) ~= "function" then return false, "close_issue not supported for " .. remote.provider end
  return mod.close_issue(root, remote, number)
end

---@param root string
---@param number integer|string
---@param comment_id string|integer
---@param body string
---@param opts? { kind?: "issue"|"pr" }
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.update_comment(root, number, comment_id, body, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.update_comment) ~= "function" then
    return false, "update_comment not supported for " .. remote.provider
  end
  return mod.update_comment(root, remote, number, comment_id, body, opts or {})
end

---@param root string
---@param number integer|string
---@param comment_id string|integer
---@param opts? { kind?: "issue"|"pr" }
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.delete_comment(root, number, comment_id, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.delete_comment) ~= "function" then
    return false, "delete_comment not supported for " .. remote.provider
  end
  return mod.delete_comment(root, remote, number, comment_id, opts or {})
end

---@class ForgeCiListMeta
---@field has_more? boolean

---@param root string
---@param opts? { branch?: string, limit?: integer }
---@param remote? ForgeRemote
---@return ForgeCiRun[], string|nil, ForgeCiListMeta|nil
function M.list_ci_runs(root, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {}, "No forge provider for this repository" end
  if type(mod.list_ci_runs) ~= "function" then return {}, "CI listing not supported for " .. remote.provider end
  return mod.list_ci_runs(root, remote, opts or {})
end

---@param root string
---@param run_id string|integer
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.cancel_ci_run(root, run_id, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.cancel_ci_run) ~= "function" then return false, "cancel_ci_run not supported for " .. remote.provider end
  return mod.cancel_ci_run(root, remote, run_id)
end

---@param root string
---@param remote? ForgeRemote
---@return ForgeWorkflow[], string|nil
function M.list_triggerable_workflows(root, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {}, "No forge provider for this repository" end
  if type(mod.list_triggerable_workflows) ~= "function" then
    return {}, "triggerable workflows not supported for " .. remote.provider
  end
  return mod.list_triggerable_workflows(root, remote)
end

---@param root string
---@param opts { workflow_id: string|integer, ref?: string, inputs?: table }
---@param remote? ForgeRemote
---@return boolean, string|nil
function M.trigger_ci(root, opts, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return false, "No forge provider for this repository" end
  if type(mod.trigger_ci) ~= "function" then return false, "trigger_ci not supported for " .. remote.provider end
  return mod.trigger_ci(root, remote, opts or {})
end

---@param root string
---@param run_id string|integer
---@param remote? ForgeRemote
---@return ForgeCiRunDetail|nil, string|nil
function M.get_ci_run(root, run_id, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return nil, "No forge provider for this repository" end
  if type(mod.get_ci_run) ~= "function" then return nil, "CI run details not supported for " .. remote.provider end
  return mod.get_ci_run(root, remote, run_id)
end

---@param root string
---@param run_id string|integer
---@param job_id string|integer
---@param remote? ForgeRemote
---@return ForgeCiJobDetail|nil, string|nil
function M.get_ci_job(root, run_id, job_id, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return nil, "No forge provider for this repository" end
  if type(mod.get_ci_job) ~= "function" then return nil, "CI job details not supported for " .. remote.provider end
  return mod.get_ci_job(root, remote, run_id, job_id)
end

---@param root string
---@param run_id string|integer
---@param job_id string|integer
---@param remote? ForgeRemote
---@return string[], string|nil
function M.get_ci_job_logs(root, run_id, job_id, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {}, "No forge provider for this repository" end
  if type(mod.get_ci_job_logs) ~= "function" then return {}, "CI logs not supported for " .. remote.provider end
  return mod.get_ci_job_logs(root, remote, run_id, job_id)
end

return M
