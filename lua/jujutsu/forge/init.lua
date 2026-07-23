local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local notify = require("jujutsu.notify")

local M = {}

---@return boolean
local function gh_available() return vim.fn.executable("gh") == 1 end

---Parse origin URL to owner/repo
---@param root string
---@return string|nil, string|nil, string|nil
local function remote_repo(root)
  local res = cli.git_remote_list.call({ cwd = root, hidden = true })
  for _, line in ipairs(res.stdout) do
    local name, url = line:match("^(%S+)%s+(%S+)")
    if name == "origin" and url then
      local provider = nil
      local owner, repo = nil, nil
      -- check for GitHub
      if url:match("^https?://github%.com/") then
        owner, repo = url:match("github%.com[:/]+([^/]+)/([^/]+)")
        provider = "github.com"
      elseif url:match("^git@github%.com:") then
        owner, repo = url:match("git@github%.com:([^/]+)/([^/]+)")
        provider = "github.com"
      -- check for GitLab
      elseif url:match("^https?://gitlab%.com/") then
        owner, repo = url:match("git://github%.com/([^/]+)/([^/]+)")
        provider = "gitlab.com"
      elseif url:match("^git@gitlab%.com:") then
        owner, repo = url:match("git@gitlab%.com:([^/]+)/([^/]+)")
        provider = "gitlab.com"
      -- check for Bitbucket
      elseif url:match("^https?://bitbucket%.org/") then
        owner, repo = url:match("bitbucket%.org/([^/]+)/([^/]+)")
        provider = "bitbucket.org"
      elseif url:match("^git@bitbucket%.org:") then
        owner, repo = url:match("git@bitbucket%.org:([^/]+)/([^/]+)")
        provider = "bitbucket.org"
      -- check for Codeberg
      elseif url:match("^https?://codeberg%.org/") then
        owner, repo = url:match("codeberg%.org/([^/]+)/([^/]+)")
        provider = "codeberg.org"
      elseif url:match("^git@codeberg%.org:") then
        owner, repo = url:match("git@codeberg%.org:([^/]+)/([^/]+)")
        provider = "codeberg.org"
      -- check for Forgejo
      elseif url:match("^https?://[^/]+%.forgejo%.org/") then
        owner, repo = url:match("forgejo%.org/([^/]+)/([^/]+)")
        provider = "forgejo.org"
      elseif url:match("^git@[^/]+%.forgejo%.org:") then
        owner, repo = url:match("git@[^/]+%.forgejo%.org:([^/]+)/([^/]+)")
        provider = "forgejo.org"
      end
      if owner and repo and provider then return owner, repo:gsub("%.git$", ""), provider end
    end
  end
  return nil, nil
end

---@param root string
---@return table<string, { number: integer, url: string }>
function M.list_prs(root)
  local map = {}
  if not config.values.forge.pr_integration or not gh_available() then return map end
  local obj = vim
    .system({ "gh", "pr", "list", "--json", "number,url,headRefName", "--limit", "50" }, {
      cwd = root,
      text = true,
    })
    :wait()
  if obj.code ~= 0 then return map end
  local ok, data = pcall(vim.json.decode, obj.stdout)
  if not ok or type(data) ~= "table" then return map end
  for _, pr in ipairs(data) do
    if pr.headRefName then map[pr.headRefName] = { number = pr.number, url = pr.url } end
  end
  return map
end

---Open browser for item under cursor / `env`
---@param env table
function M.open_under_cursor(env)
  local root = env.root or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local item = env.item

  if item and item.type == "bookmark" and item.data and item.data.bookmark then
    local bm = item.data.bookmark
    if bm.pr_url then
      vim.ui.open(bm.pr_url)
      return
    end
    local name = bm.name
    local prs = M.list_prs(root)
    if prs[name] then
      vim.ui.open(prs[name].url)
      return
    end
  end

  if item and item.data and item.data.change then
    local owner, repo, provider = remote_repo(root)
    local commit = item.data.change.commit_id
    if owner and repo and provider and commit then
      if provider == "github.com" then
        vim.ui.open(string.format("https://" .. provider .. "/%s/%s/commit/%s", owner, repo, commit))
      elseif provider == "gitlab.com" then
        vim.ui.open(string.format("https://" .. provider .. "/%s/%s/-/commit/%s", owner, repo, commit))
      elseif provider == "bitbucket.org" then
        vim.ui.open(string.format("https://" .. provider .. "/%s/%s/commits/%s", owner, repo, commit))
      elseif provider == "codeberg.org" then
        vim.ui.open(string.format("https://" .. provider .. "/%s/%s/commit/%s", owner, repo, commit))
      elseif provider == "forgejo.org" then
        vim.ui.open(string.format("https://" .. provider .. "/%s/%s/commit/%s", owner, repo, commit))
      else
        notify.warn("Unsupported provider: " .. provider)
      end
      return
    end
  end

  -- Fallback: open repo
  local owner, repo, provider = remote_repo(root)
  if owner and repo and provider then
    if provider == "github.com" then
      vim.ui.open(string.format("https://github.com/%s/%s", owner, repo))
    elseif provider == "gitlab.com" then
      vim.ui.open(string.format("https://gitlab.com/%s/%s", owner, repo))
    elseif provider == "bitbucket.org" then
      vim.ui.open(string.format("https://bitbucket.org/%s/%s", owner, repo))
    elseif provider == "codeberg.org" then
      vim.ui.open(string.format("https://codeberg.org/%s/%s", owner, repo))
    elseif provider == "forgejo.org" then
      vim.ui.open(string.format("https://forgejo.org/%s/%s", owner, repo))
    else
      notify.warn("Unsupported provider: " .. provider)
    end
  else
    notify.warn("Could not determine remote URL to open")
  end
end

---Annotate bookmark display names with PR numbers
---@param bookmarks table[]
---@param root string
---@return table[]
function M.annotate_bookmarks(bookmarks, root)
  if not config.values.forge.pr_integration then return bookmarks end
  local prs = M.list_prs(root)
  for _, bm in ipairs(bookmarks) do
    local pr = prs[bm.name]
    if pr then
      bm.pr = pr.number
      bm.pr_url = pr.url
    end
  end
  return bookmarks
end

return M
