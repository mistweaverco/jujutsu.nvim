local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local notify = require("jujutsu.notify")

local M = {}

---@return boolean
local function gh_available() return vim.fn.executable("gh") == 1 end

---Parse origin URL to owner/repo
---@param root string
---@return string|nil, string|nil
local function remote_repo(root)
  local res = cli.git_remote_list.call({ cwd = root, hidden = true })
  for _, line in ipairs(res.stdout) do
    local name, url = line:match("^(%S+)%s+(%S+)")
    if name == "origin" and url then
      -- Match `ssh`/`https` remotes, including `git@github.com:/owner/repo.git`
      -- and dotted repo names like `jujutsu.nvim`.
      -- We need to preserve the repo name as-is, but strip the `.git` suffix if present.
      local owner, repo = url:match("github%.com[:/]+([^/]+)/([^/]+)")
      if owner and repo then return owner, repo:gsub("%.git$", "") end
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

---Open browser for item under cursor / env
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
    local owner, repo = remote_repo(root)
    local commit = item.data.change.commit_id
    if owner and repo and commit then
      vim.ui.open(string.format("https://github.com/%s/%s/commit/%s", owner, repo, commit))
      return
    end
  end

  -- Fallback: open repo
  local owner, repo = remote_repo(root)
  if owner and repo then
    vim.ui.open(string.format("https://github.com/%s/%s", owner, repo))
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
