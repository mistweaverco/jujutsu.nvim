local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")
local notify = require("jujutsu.notify")
local select = require("jujutsu.diff.select")

local M = {}

---@param popup table
---@return any
local function base(popup)
  local rev = common.commit(popup) or "@"
  local b = cli.split.revision(rev)
  local args = popup:get_arguments()
  if vim.tbl_contains(args, "--parallel") then b = b.parallel end
  return b
end

---@param popup table
---@return boolean
local function want_parallel(popup) return vim.tbl_contains(popup:get_arguments(), "--parallel") end

---@param popup table
---@return { path: string, mode: "file"|"hunks", hunk_indices: integer[], file: table }|nil
local function resolve_selection(popup)
  local env = popup.state.env or {}
  if env.selection and env.selection.path then return env.selection end

  local item = env.item
  if not item or not item.data or not item.data.file then return nil end
  local file = item.data.file
  if item.type == "diff" and item.data.diff_index and file.diff then
    local hunks = require("jujutsu.diff.hunks")
    local parsed = hunks.parse_hunks(file.diff)
    local idx = hunks.hunk_index_at(parsed, item.data.diff_index)
    if idx ~= nil then
      return {
        path = file.path,
        mode = "hunks",
        hunk_indices = { idx },
        file = file,
      }
    end
  end
  return {
    path = file.path,
    mode = "file",
    hunk_indices = {},
    file = file,
  }
end

--- Interactive split (default jj behavior when no filesets are given).
function M.split(popup) common.run_interactive(popup, base(popup), { title = " jj split " }) end

--- Split the file under the cursor, or only selected hunks (visual / hunk line).
function M.split_file(popup)
  local sel = resolve_selection(popup)
  if not sel then
    notify.warn("No file under cursor")
    return
  end

  local root = common.root(popup)
  local rev = common.commit(popup) or "@"
  local parallel = want_parallel(popup)

  if sel.mode == "file" or not sel.hunk_indices or #sel.hunk_indices == 0 then
    -- Whole file - non-interactive fileset split.
    local b = base(popup).message(sel.path).files(sel.path)
    common.run(popup, b)
    return
  end

  -- Ensure we have a git diff to parse hunks from.
  local file = sel.file
  if not file.diff or #file.diff == 0 then file.diff = require("jujutsu.jj.status").file_diff(root, sel.path) end
  if not file.diff or #file.diff == 0 then
    notify.warn("No diff for " .. sel.path)
    return
  end

  local content, err = select.selected_content({
    cwd = root,
    revision = rev,
    path = sel.path,
    file_diff = file.diff,
    hunk_indices = sel.hunk_indices,
  })
  if not content then
    notify.warn(err or "Failed to build selected hunks")
    return
  end

  local msg = string.format("%s (hunks %s)", sel.path, table.concat(sel.hunk_indices, ","))
  local res = select.split_with_contents({
    cwd = root,
    revision = rev,
    message = msg,
    parallel = parallel,
    files = { [sel.path] = content },
  })
  if res and res.code ~= 0 then notify.error("Split failed") end
end

--- Interactive split, rebasing selected changes onto a picked revision.
function M.split_onto(popup)
  local root = common.root(popup)
  local onto = finder.pick_revision({ prompt = "Split onto", cwd = root })
  if onto then common.run_interactive(popup, base(popup).onto(onto), { title = " jj split " }) end
end

return M
