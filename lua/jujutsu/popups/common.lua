local cli = require("jujutsu.jj.cli")

local M = {}

---@return string
function M.root(popup)
  if popup and popup.state and popup.state.env and popup.state.env.root then return popup.state.env.root end
  local repo = require("jujutsu.jj.repository")
  return repo.root() or vim.fn.getcwd()
end

---@param popup table
---@return string|nil
function M.commit(popup)
  local env = popup.state.env or {}
  return env.commit or (env.change and env.change.change_id) or nil
end

---@param popup table
---@return string|nil
function M.path(popup)
  local env = popup.state.env or {}
  if env.path and env.path ~= "" then return env.path end
  local item = env.item
  if item and item.data and item.data.file and item.data.file.path then return item.data.file.path end
  return nil
end

---@param popup table
---@param builder any cli builder that supports call_async
function M.run(popup, builder)
  local res = builder.call_async({ cwd = M.root(popup), hidden = false })
  return res
end

---Run a jj command in a real terminal (needed for `:builtin` / interactive TUIs).
---Closes the popup first so it does not steal focus from the terminal.
---@param popup table
---@param builder any
---@param opts? { title?: string }
function M.run_interactive(popup, builder, opts)
  opts = opts or {}
  local cmd = cli._build_cmd(builder, { color = "auto" })
  local cwd = M.root(popup)
  local title = opts.title or (" " .. table.concat(cmd, " ", 2) .. " ")
  if popup and popup.close then popup:close() end
  vim.schedule(function()
    require("jujutsu.term").run(cmd, {
      cwd = cwd,
      title = title,
    })
  end)
end

return M
