local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local editor = require("jujutsu.buffers.editor")
local finder = require("jujutsu.finder")

local M = {}

---@param popup table
---@param b any
---@return any
local function flags(popup, b)
  local args = popup:get_arguments()
  if vim.tbl_contains(args, "--keep-emptied") then b = b.keep_emptied end
  if vim.tbl_contains(args, "--use-destination-message") then b = b.use_destination_message end
  return b
end

---@param popup table
---@return boolean
local function use_destination_message(popup)
  return vim.tbl_contains(popup:get_arguments(), "--use-destination-message")
end

---@param popup table
---@return boolean
local function keep_emptied(popup) return vim.tbl_contains(popup:get_arguments(), "--keep-emptied") end

---@param root string
---@param rev string
---@return string
local function description(root, rev)
  local res = cli.log.revisions(rev).no_graph.template("description").limit(1).call({ cwd = root, hidden = true })
  if res.code ~= 0 then return "" end
  return vim.trim(table.concat(res.stdout, "\n"))
end

---Mirrors jj's try_combine_messages: editor is needed when the source will be
---abandoned and both source and destination have non-empty descriptions.
---@param from_desc string
---@param into_desc string
---@param popup table
---@return boolean
local function needs_combined_edit(from_desc, into_desc, popup)
  if use_destination_message(popup) or keep_emptied(popup) then return false end
  return from_desc ~= "" and into_desc ~= ""
end

---@param from_desc string
---@param into_desc string
---@return string
local function combined_initial(from_desc, into_desc)
  local parts = {
    "# Enter a description for the combined commit.",
    "# Description from the destination commit:",
    into_desc,
    "",
    "# Description from source commit:",
    from_desc,
  }
  return table.concat(parts, "\n")
end

---@param popup table
---@param builder any
---@param from string
---@param into string
local function run_squash(popup, builder, from, into)
  local root = common.root(popup)
  local from_desc = description(root, from)
  local into_desc = description(root, into)

  if not needs_combined_edit(from_desc, into_desc, popup) then
    common.run(popup, flags(popup, builder))
    return
  end

  editor.open({
    root = root,
    revision = into,
    initial = combined_initial(from_desc, into_desc),
    apply = function(msg) flags(popup, builder).message(msg).call_async({ cwd = root, hidden = false }) end,
    on_submit = function() require("jujutsu").refresh() end,
  })
end

function M.squash_parent(popup)
  local rev = common.commit(popup) or "@"
  run_squash(popup, cli.squash.revision(rev), rev, rev .. "-")
end

function M.squash_into(popup)
  local root = common.root(popup)
  local into = finder.pick_revision({ prompt = "Squash into", cwd = root })
  if into then run_squash(popup, cli.squash.into(into), "@", into) end
end

function M.squash_from(popup)
  local root = common.root(popup)
  local from = common.commit(popup) or finder.pick_revision({ prompt = "Squash from", cwd = root })
  if not from then return end
  local into = finder.pick_revision({ prompt = "Squash into", cwd = root })
  if into then run_squash(popup, cli.squash.from(from).into(into), from, into) end
end

return M
