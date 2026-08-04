local actions = require("jujutsu.popups.forge.actions")
local builder = require("jujutsu.popup.builder")
local common = require("jujutsu.popups.common")
local provider = require("jujutsu.forge.provider")

local M = {}

function M.create(env)
  local root = (env and env.root) or common.root({ state = { env = env or {} } })
  local rem = provider.remote(root)
  local caps = provider.capabilities(rem)
  local has_ci = caps.ci.list or caps.ci.trigger

  local p = builder
    .builder()
    :name("ForgePopup")
    :group_heading("Review")
    :action_if(caps.prs.list, "r", "Review open PR/MR", actions.review, { persist_popup = true })
    :new_action_group("Pull requests")
    :action_if(
      caps.prs.search or caps.prs.list,
      "p",
      "Browse / search PRs",
      actions.browse_prs,
      { persist_popup = true }
    )
    :action_if(caps.prs.create, "P", "Create PR", actions.create_pr, { persist_popup = true })
    :action_if(caps.prs.list, "o", "Open PR by number", actions.open_pr, { persist_popup = true })
    :new_action_group("Issues")
    :action_if(
      caps.issues.search or caps.issues.list,
      "i",
      "Browse / search issues",
      actions.browse_issues,
      { persist_popup = true }
    )
    :action_if(caps.issues.create, "I", "Create issue", actions.create_issue, { persist_popup = true })
    :action("n", "Open by number", actions.open_issue, { persist_popup = true })
    :new_action_group_if(has_ci, "CI")
    :action_if(has_ci and caps.ci.list, "c", "List CI runs", actions.list_ci, { persist_popup = true })
    :action_if(has_ci and caps.ci.trigger, "t", "Trigger workflow", actions.trigger_ci, { persist_popup = true })
    :env(env or {})
    :build()
  p:show()
  return p
end

return M
