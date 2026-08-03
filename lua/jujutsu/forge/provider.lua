local bitbucket = require("jujutsu.forge.bitbucket")
local credentials = require("jujutsu.forge.credentials")
local forgejo = require("jujutsu.forge.forgejo")
local github = require("jujutsu.forge.github")
local gitlab = require("jujutsu.forge.gitlab")
local remote_mod = require("jujutsu.forge.remote")

local M = {}

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
---@field labels string[]
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
  return mod.get_topic(root, remote, number, opts or {})
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

return M
