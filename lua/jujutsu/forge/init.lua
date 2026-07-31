local config = require("jujutsu.config")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local remote_mod = require("jujutsu.forge.remote")

local M = {}

M.remote = remote_mod
M.provider = provider

---@param root string
---@return table<string, { number: integer, url: string }>
function M.list_prs(root)
  local map = {}
  if not config.values.forge.pr_integration then return map end
  local rem = remote_mod.detect(root)
  if not rem or not provider.available(rem) then return map end
  for _, pr in ipairs(provider.list_prs(root, rem)) do
    if pr.head_ref and pr.head_ref ~= "" then map[pr.head_ref] = { number = pr.number, url = pr.url } end
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
    local rem = remote_mod.detect(root)
    local commit = item.data.change.commit_id
    if rem and commit then
      vim.ui.open(remote_mod.commit_url(rem, commit))
      return
    end
  end

  local rem = remote_mod.detect(root)
  if rem then
    vim.ui.open(remote_mod.repo_url(rem))
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
