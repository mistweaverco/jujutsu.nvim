local cli = require("jujutsu.jj.cli")

local M = {}

-- jj bookmark list template context uses `self.*` accessors, not log-style keywords.
local BOOKMARK_TEMPLATE = table.concat({
  'self.name() ++ "\\t" ++ if(self.remote(), self.remote(), "") ++ "\\t" ++',
  'if(self.normal_target(), self.normal_target().change_id().short(8) ++ "\\t" ++',
  'self.normal_target().commit_id().short(8) ++ "\\t" ++',
  'self.normal_target().committer().timestamp() ++ "\\t" ++',
  'self.normal_target().description().first_line(), "\\t\\t\\t\\t") ++ "\\t" ++',
  'if(self.present(), "1", "0") ++ "\\t" ++ if(self.conflict(), "1", "0") ++ "\\n"',
}, " ")

---@param lines string[]
---@return table[]
function M.parse_template_list(lines)
  local items = {}
  for _, line in ipairs(lines) do
    if line ~= "" and not line:match("^Hint:") then
      local parts = vim.split(line, "\t", { plain = true })
      if #parts >= 8 then
        local name = parts[1]
        local remote = parts[2] ~= "" and parts[2] or ""
        local change_id = parts[3]
        local commit_id = parts[4]
        local timestamp = parts[5]
        local description = parts[6]
        local present = parts[7] == "1"
        local conflict = parts[8] == "1"
        local deleted = not present

        if conflict then
          description = "(conflicted)"
        elseif deleted then
          description = "(deleted)"
        end

        table.insert(items, {
          name = name,
          remote = remote,
          change_id = change_id,
          commit_id = commit_id,
          timestamp = timestamp,
          description = description,
          deleted = deleted,
          conflict = conflict,
          -- Legacy field used by commit view navigation
          target = change_id,
        })
      end
    end
  end
  return items
end

---@param root string
---@return table[]
function M.list(root)
  local res = cli.bookmark_list.all.template(BOOKMARK_TEMPLATE).call({
    cwd = root,
    hidden = true,
    trim = true,
  })
  if res.code ~= 0 then return {} end
  return M.parse_template_list(res.stdout)
end

---@param bookmark_at_remote string e.g. "main@origin"
---@return table
function M.track(bookmark_at_remote)
  local name, remote = bookmark_at_remote:match("^(.+)@(.+)$")
  if name and remote then return cli.bookmark_track.args(name).remote(remote) end
  return cli.bookmark_track.args(bookmark_at_remote)
end

---@param bookmark_at_remote string e.g. "main@origin"
---@return table
function M.untrack(bookmark_at_remote) return cli.bookmark_untrack.args(bookmark_at_remote) end

M.template = BOOKMARK_TEMPLATE

return M
