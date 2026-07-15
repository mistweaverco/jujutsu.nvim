local Popup = require("jujutsu.popup")

local M = {}

---@class PopupBuilder
local Builder = {}
Builder.__index = Builder

function M.new()
  return setmetatable({
    state = {
      name = nil,
      args = {},
      config = {},
      actions = { {} },
      env = {},
      keys = {},
    },
  }, Builder)
end

function Builder:name(name)
  self.state.name = name
  return self
end

function Builder:env(env)
  self.state.env = env or {}
  return self
end

function Builder:new_action_group(heading)
  table.insert(self.state.actions, { { heading = heading or "" } })
  return self
end

function Builder:new_action_group_if(cond, heading)
  if cond then return self:new_action_group(heading) end
  return self
end

function Builder:group_heading(heading)
  table.insert(self.state.actions[#self.state.actions], { heading = heading })
  return self
end

function Builder:group_heading_if(cond, heading)
  if cond then return self:group_heading(heading) end
  return self
end

function Builder:arg_heading(heading)
  table.insert(self.state.args, { type = "heading", heading = heading })
  return self
end

function Builder:switch(key, cli, description, opts)
  opts = opts or {}
  table.insert(self.state.args, {
    type = "switch",
    id = (opts.key_prefix or "-") .. key,
    key = key,
    key_prefix = opts.key_prefix or "-",
    cli = cli,
    cli_base = cli,
    description = description,
    enabled = opts.enabled or false,
    internal = opts.internal or false,
    cli_prefix = opts.cli_prefix or "--",
  })
  return self
end

function Builder:switch_if(cond, key, cli, description, opts)
  if cond then return self:switch(key, cli, description, opts) end
  return self
end

function Builder:option(key, cli, value, description, opts)
  opts = opts or {}
  table.insert(self.state.args, {
    type = "option",
    id = (opts.key_prefix or "=") .. key,
    key = key,
    key_prefix = opts.key_prefix or "=",
    cli = cli,
    value = value,
    description = description,
    cli_prefix = opts.cli_prefix or "--",
    separator = opts.separator or "=",
  })
  return self
end

function Builder:action(keys, description, callback, opts)
  opts = opts or {}
  if type(keys) == "string" then keys = { keys } end
  table.insert(self.state.actions[#self.state.actions], {
    keys = keys,
    description = description,
    callback = callback,
    persist_popup = opts.persist_popup or false,
  })
  return self
end

function Builder:action_if(cond, keys, description, callback, opts)
  if cond then return self:action(keys, description, callback, opts) end
  return self
end

function Builder:spacer()
  table.insert(self.state.actions[#self.state.actions], {
    keys = "",
    description = "",
    heading = "",
  })
  return self
end

function Builder:build()
  if not self.state.name then error("Popup needs a name") end
  return Popup.create(self.state)
end

---Convenience: create a builder
function M.builder() return M.new() end

return M
