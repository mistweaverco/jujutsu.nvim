local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")

local M = {}

local function open_log(root, revset) require("jujutsu.buffers.log_view").open(root, revset) end

function M.log(popup)
  local revset = "all()"
  for _, arg in ipairs(popup.state.args or {}) do
    if arg.type == "option" and arg.cli == "revisions" and arg.value and arg.value ~= "" then revset = arg.value end
  end
  open_log(common.root(popup), revset)
end

function M.log_all(popup) open_log(common.root(popup), "all()") end

function M.log_head(popup) open_log(common.root(popup), "ancestors(@)") end

function M.log_revset(popup)
  local root = common.root(popup)
  local rev = finder.input({ prompt = "Revset: ", default = "all()" })
  if rev and rev ~= "" then open_log(root, rev) end
end

return M
