local M = {}

local defaults = {
  jj_binary = "auto",
  disable_hint = false,
  disable_context_highlighting = false,
  disable_signs = false,
  disable_insert_on_commit = "auto",
  filewatcher = { enabled = true },
  graph_style = "ascii",
  commit_date_format = nil,
  log_date_format = nil,
  process_spinner = true,
  remember_settings = true,
  use_per_project_settings = true,
  ignored_settings = {},
  highlight = { italic = true, bold = true, underline = true },
  use_default_keymaps = true,
  kind = "tab",
  floating = {
    relative = "editor",
    width = 0.8,
    height = 0.7,
    style = "minimal",
    border = "rounded",
  },
  disable_line_numbers = true,
  disable_relative_line_numbers = true,
  console_timeout = 2000,
  auto_show_console = true,
  auto_show_console_on = "output",
  auto_close_console = true,
  notification_icon = "󰊢",
  workspace_open_command = nil,
  workspace_initialize_command = nil,
  workspace_worktrees_directory = "~/.worktrees",
  status = {
    show_head_commit_hash = true,
    recent_commit_count = 10,
    HEAD_padding = 10,
    HEAD_folded = false,
    mode_text = {
      M = "modified",
      A = "added",
      D = "deleted",
      R = "renamed",
      C = "copied",
      N = "new file",
      ["?"] = "untracked",
    },
  },
  commit_editor = {
    kind = "tab",
    show_diff = true,
    diff_split_kind = "split",
    spell_check = true,
  },
  commit_view = { kind = "vsplit" },
  stat_view = { kind = "vsplit" },
  log_view = { kind = "tab" },
  popup = { kind = "split" },
  signs = {
    hunk = { "", "" },
    item = { ">", "v" },
    section = { ">", "v" },
  },
  integrations = {
    telescope = nil,
    diffview = nil,
    codediff = nil,
    fzf_lua = nil,
    mini_pick = nil,
    snacks = nil,
    juu = nil,
  },
  diff_viewer = nil,
  forge = {
    pr_integration = true,
    hosts = {},
  },
  sections = {
    files = { folded = false, hidden = false },
    conflicts = { folded = false, hidden = false },
    untracked = { folded = false, hidden = false },
    bookmarks = { folded = true, hidden = false, show_deleted = true, show_remote = true },
    recent = { folded = true, hidden = false },
  },
  mappings = {
    commit_editor = {
      ["q"] = "Close",
      ["<c-c><c-c>"] = "Submit",
      ["<c-c><c-k>"] = "Abort",
    },
    commit_editor_I = {
      ["<c-c><c-c>"] = "Submit",
      ["<c-c><c-k>"] = "Abort",
    },
    finder = {
      ["<cr>"] = "Select",
      ["<c-c>"] = "Close",
      ["<esc>"] = "Close",
      ["<c-n>"] = "Next",
      ["<c-p>"] = "Previous",
      ["<down>"] = "Next",
      ["<up>"] = "Previous",
      ["<tab>"] = "InsertCompletion",
      ["<c-y>"] = "CopySelection",
      ["<space>"] = "MultiselectToggleNext",
    },
    popup = {
      ["?"] = "HelpPopup",
      ["b"] = "BookmarkPopup",
      ["c"] = "ChangePopup",
      ["d"] = "DiffPopup",
      ["f"] = "FetchPopup",
      ["l"] = "LogPopup",
      ["m"] = "RemotePopup",
      ["p"] = "PushPopup",
      ["r"] = "RebasePopup",
      ["s"] = "SquashPopup",
      ["u"] = "UndoPopup",
      ["w"] = "WorkspacePopup",
    },
    status = {
      ["j"] = "MoveDown",
      ["k"] = "MoveUp",
      ["q"] = "Close",
      ["1"] = "Depth1",
      ["2"] = "Depth2",
      ["3"] = "Depth3",
      ["4"] = "Depth4",
      ["Q"] = "Command",
      ["<tab>"] = "Toggle",
      ["za"] = "Toggle",
      ["zo"] = "OpenFold",
      ["zc"] = "CloseFold",
      ["x"] = "Discard",
      ["K"] = "Untrack",
      ["y"] = "ShowRefs",
      ["$"] = "CommandHistory",
      ["Y"] = "YankSelected",
      ["<c-r>"] = "RefreshBuffer",
      ["<cr>"] = "GoToFile",
      ["<c-v>"] = "VSplitOpen",
      ["<c-x>"] = "SplitOpen",
      ["<c-t>"] = "TabOpen",
      ["D"] = "Describe",
      ["E"] = "Edit",
      ["O"] = "NewOn",
      ["B"] = "NewBefore",
      ["F"] = "ForgetBookmark",
      ["P"] = "Split",
      ["S"] = "OpenStat",
      ["o"] = "OpenBrowser",
      ["{"] = "GoToPreviousHunkHeader",
      ["}"] = "GoToNextHunkHeader",
      ["<c-n>"] = "NextSection",
      ["<c-p>"] = "PreviousSection",
    },
    log_view = {
      ["q"] = "Close",
      ["<cr>"] = "OpenCommit",
      ["S"] = "OpenStat",
      ["E"] = "Edit",
      ["O"] = "NewOn",
      ["D"] = "Describe",
      ["P"] = "Split",
      ["x"] = "Abandon",
      ["b"] = "SetBookmark",
      ["<c-r>"] = "RefreshBuffer",
    },
    commit_view = {
      ["q"] = "Close",
      ["<esc>"] = "Close",
      ["S"] = "OpenStat",
    },
  },
}

M.values = vim.deepcopy(defaults)

local mapping_cache = {}

local function get_reversed_maps(set)
  if not mapping_cache[set] then
    local result = {}
    for k, v in pairs(M.values.mappings[set] or {}) do
      if v then
        local current = result[v]
        if current then
          table.insert(current, k)
        else
          result[v] = { k }
        end
      end
    end
    setmetatable(result, {
      __index = function() return { " " } end,
    })
    mapping_cache[set] = result
  end
  return mapping_cache[set]
end

function M.get_reversed_status_maps() return get_reversed_maps("status") end

function M.get_reversed_popup_maps() return get_reversed_maps("popup") end

function M.get_reversed_finder_maps() return get_reversed_maps("finder") end

---@param name string
---@return boolean
function M.check_integration(name)
  local val = M.values.integrations[name]
  if val == false then return false end
  if val == true then return true end
  -- auto-detect
  local modules = {
    telescope = "telescope",
    fzf_lua = "fzf-lua",
    mini_pick = "mini.pick",
    snacks = "snacks",
    diffview = "diffview",
    codediff = "codediff",
    juu = "juu.progress",
  }
  local mod = modules[name]
  if not mod then return false end
  return pcall(require, mod)
end

---@param opts? table
function M.setup(opts)
  mapping_cache = {}
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get_defaults() return vim.deepcopy(defaults) end

return M
