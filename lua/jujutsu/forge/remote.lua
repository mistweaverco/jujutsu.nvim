local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

---@class ForgeRemote
---@field provider "github"|"gitlab"|"bitbucket"|"forgejo"
---@field host string
---@field owner string
---@field repo string
---@field url string

---@param host string
---@return string|nil kind
local function host_kind(host)
  host = host:lower()
  local hosts = (config.values.forge and config.values.forge.hosts) or {}
  if hosts[host] then return hosts[host] end
  if host == "github.com" then return "github" end
  if host == "gitlab.com" or host:find("gitlab", 1, true) then return "gitlab" end
  if host == "bitbucket.org" then return "bitbucket" end
  if host == "codeberg.org" or host:match("%.forgejo%.org$") then return "forgejo" end
  return nil
end

---@param url string
---@return ForgeRemote|nil
function M.parse_url(url)
  if not url or url == "" then return nil end
  url = url:gsub("%.git$", "")

  local host, path
  if url:match("^git@") then
    host, path = url:match("^git@([^:]+):(.+)$")
  elseif url:match("^ssh://") then
    host, path = url:match("^ssh://[^@]*@?([^/]+)/(.+)$")
  elseif url:match("^https?://") then
    host, path = url:match("^https?://([^/]+)/(.+)$")
  end
  if not host or not path then return nil end

  -- strip port from host
  host = host:gsub(":%d+$", "")
  local kind = host_kind(host)
  if not kind then return nil end

  path = path:gsub("^/+", ""):gsub("/+$", "")
  local owner, repo
  if kind == "gitlab" then
    -- support nested groups: group/sub/repo
    local parts = vim.split(path, "/", { plain = true })
    if #parts < 2 then return nil end
    repo = parts[#parts]
    owner = table.concat(vim.list_slice(parts, 1, #parts - 1), "/")
  else
    owner, repo = path:match("^([^/]+)/([^/]+)")
  end
  if not owner or not repo then return nil end

  return {
    provider = kind,
    host = host,
    owner = owner,
    repo = repo,
    url = url,
  }
end

---@param root string
---@return ForgeRemote|nil
function M.detect(root)
  local res = cli.git_remote_list.call({ cwd = root, hidden = true })
  local origin = nil
  local first = nil
  for _, line in ipairs(res.stdout or {}) do
    local name, url = line:match("^(%S+)%s+(%S+)")
    if name and url then
      local parsed = M.parse_url(url)
      if parsed then
        if name == "origin" then
          origin = parsed
          break
        end
        if not first then first = parsed end
      end
    end
  end
  return origin or first
end

---@param remote ForgeRemote
---@param commit string
---@return string
function M.commit_url(remote, commit)
  if remote.provider == "github" then
    return string.format("https://%s/%s/%s/commit/%s", remote.host, remote.owner, remote.repo, commit)
  elseif remote.provider == "gitlab" then
    return string.format("https://%s/%s/%s/-/commit/%s", remote.host, remote.owner, remote.repo, commit)
  elseif remote.provider == "bitbucket" then
    return string.format("https://%s/%s/%s/commits/%s", remote.host, remote.owner, remote.repo, commit)
  else
    return string.format("https://%s/%s/%s/commit/%s", remote.host, remote.owner, remote.repo, commit)
  end
end

---@param remote ForgeRemote
---@return string
function M.repo_url(remote) return string.format("https://%s/%s/%s", remote.host, remote.owner, remote.repo) end

return M
