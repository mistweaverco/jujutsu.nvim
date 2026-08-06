local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local config = require("jujutsu.config")

---@class PopupData
---@field state table
---@field buf table
---@field switches table<string, table>
---@field options table<string, table>

local M = {}

---@param state table
---@return PopupData
function M.create(state)
  ---@type PopupData
  local popup = {
    state = state,
    buf = nil,
    switches = {},
    options = {},
  }

  for _, arg in ipairs(state.args or {}) do
    if arg.type == "switch" then
      popup.switches[arg.cli_base or arg.cli] = arg
    elseif arg.type == "option" then
      popup.options[arg.cli] = arg
    end
  end

  setmetatable(popup, { __index = M })
  return popup
end

function M:get_arguments()
  local args = {}
  for _, arg in ipairs(self.state.args or {}) do
    if arg.type == "switch" and arg.enabled and not arg.internal then
      table.insert(args, arg.cli_prefix .. arg.cli)
    elseif arg.type == "option" and arg.value and arg.value ~= "" then
      table.insert(args, arg.cli_prefix .. arg.cli .. (arg.separator or "=") .. arg.value)
    end
  end
  return args
end

function M:get_internal_arguments()
  local args = {}
  for _, arg in ipairs(self.state.args or {}) do
    if arg.type == "switch" and arg.enabled and arg.internal then args[arg.cli] = true end
  end
  return args
end

function M:close()
  if self.buf then
    Buffer.close(self.buf)
    self.buf = nil
  end
end

local function render_lines(popup)
  local lines = {}
  local highlights = {}
  local key_actions = {}

  local function add(text, hl)
    table.insert(lines, text)
    if hl then table.insert(highlights, { line = #lines - 1, col = 0, end_col = #text, hl = hl }) end
  end

  add(popup.state.name or "Popup", "JujutsuPopupHeading")
  add("")

  -- Args section
  local has_args = false
  for _, arg in ipairs(popup.state.args or {}) do
    if arg.type == "heading" then
      add(arg.heading, "JujutsuPopupHeading")
      has_args = true
    elseif arg.type == "switch" then
      has_args = true
      local mark = arg.enabled and "[X]" or "[ ]"
      local hl = arg.enabled and "JujutsuPopupSwitchOn" or "JujutsuPopupSwitchOff"
      local text = string.format("  %s%s %s %s", arg.key_prefix or "-", arg.key, mark, arg.description)
      add(text, hl)
      key_actions[(arg.key_prefix or "-") .. arg.key] = function()
        arg.enabled = not arg.enabled
        popup:redraw()
      end
      -- also bind without prefix for convenience on the key alone if not conflicting
    elseif arg.type == "option" then
      has_args = true
      local text = string.format("  %s%s %s = %s", arg.key_prefix or "=", arg.key, arg.description, arg.value or "")
      add(text, "JujutsuPopupAction")
      key_actions[(arg.key_prefix or "=") .. arg.key] = function()
        async.void(function()
          local val = require("jujutsu.finder").input({
            prompt = arg.description .. ": ",
            default = arg.value or "",
            allow_empty = true,
          })
          if val ~= nil then
            arg.value = val
            popup:redraw()
          end
        end)
      end
    end
  end
  if has_args then add("") end

  -- Actions
  for _, group in ipairs(popup.state.actions or {}) do
    for _, action in ipairs(group) do
      if action.heading and action.heading ~= "" and not action.keys then
        add(action.heading, "JujutsuPopupHeading")
      elseif action.keys and action.keys ~= "" then
        local keys = type(action.keys) == "table" and table.concat(action.keys, ",") or action.keys
        if keys ~= "" then
          local text = string.format("  %-6s %s", keys, action.description or "")
          add(text, "JujutsuPopupAction")
          -- highlight key part
          table.insert(highlights, {
            line = #lines - 1,
            col = 2,
            end_col = 2 + #keys,
            hl = "JujutsuPopupKey",
          })
          local keys_list = type(action.keys) == "table" and action.keys or { action.keys }
          for _, k in ipairs(keys_list) do
            key_actions[k] = function()
              if action.callback then
                async.void(function()
                  action.callback(popup)
                  if not action.persist_popup then
                    vim.schedule(function()
                      popup:close()
                      require("jujutsu").refresh()
                    end)
                  end
                end)
              end
            end
          end
        end
      end
    end
    add("")
  end

  add("  q      Close", "JujutsuHint")
  key_actions["q"] = function() popup:close() end
  key_actions["<esc>"] = key_actions["q"]

  return lines, highlights, key_actions
end

function M:redraw()
  if not self.buf then return end
  local lines, highlights, key_actions = render_lines(self)
  Buffer.render(self.buf, lines, highlights)
  self._key_actions = key_actions
end

function M:show()
  local buf = Buffer.create("jujutsu://popup/" .. (self.state.name or "popup"), "jujutsu-popup")
  Buffer.open(buf, config.values.popup.kind or "split")
  self.buf = buf
  self:redraw()
  Buffer.focus(buf)

  -- Bind keys via keymap that looks up current actions
  local function bind(key)
    vim.keymap.set("n", key, function()
      local fn = self._key_actions and self._key_actions[key]
      if fn then fn() end
    end, { buffer = buf.bufnr, silent = true, nowait = true })
  end

  -- Collect all keys used
  local seen = {}
  local function mark(k)
    if k and k ~= "" and not seen[k] then
      seen[k] = true
      bind(k)
    end
  end
  mark("q")
  mark("<esc>")
  for _, arg in ipairs(self.state.args or {}) do
    if arg.type == "switch" then
      mark((arg.key_prefix or "-") .. arg.key)
    elseif arg.type == "option" then
      mark((arg.key_prefix or "=") .. arg.key)
    end
  end
  for _, group in ipairs(self.state.actions or {}) do
    for _, action in ipairs(group) do
      local keys_list = type(action.keys) == "table" and action.keys or { action.keys }
      for _, k in ipairs(keys_list) do
        mark(k)
      end
    end
  end
end

return M
