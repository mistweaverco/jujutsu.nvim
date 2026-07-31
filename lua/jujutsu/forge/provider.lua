local bitbucket = require("jujutsu.forge.bitbucket")
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
  return mod ~= nil and mod.available()
end

---@param root string
---@param remote? ForgeRemote
-- luacheck: ignore 631
---@return { number: integer, title: string, url: string, head_ref: string, base_ref: string, head_sha: string, base_sha: string }[]
function M.list_prs(root, remote)
  remote = remote or remote_mod.detect(root)
  local mod = backend(remote)
  if not mod or not remote then return {} end
  if remote.provider == "github" then return mod.list_prs(root) end
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
---@return boolean, string|nil
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

---@param remote ForgeRemote|nil
---@return string[]
function M.submit_events(remote)
  if not remote then return { "COMMENT" } end
  if remote.provider == "github" then return { "COMMENT", "APPROVE", "REQUEST_CHANGES", "DRAFT" } end
  return { "COMMENT", "APPROVE", "REQUEST_CHANGES" }
end

return M
