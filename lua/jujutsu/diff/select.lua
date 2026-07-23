local Process = require("jujutsu.process")
local hunks_mod = require("jujutsu.diff.hunks")
local shell = require("jujutsu.jj.shell")

local M = {}

---Write a one-shot diff-editor script that installs precomputed file contents into $right.
---@param files table<string, string[]> path → lines
---@return string script_path
local function write_tool_script(files)
  local dir = vim.fn.tempname() .. "-jujutsu-tool"
  vim.fn.mkdir(dir, "p")
  local content_dir = dir .. "/content"
  vim.fn.mkdir(content_dir, "p")

  for path, lines in pairs(files) do
    local dest = content_dir .. "/" .. path
    vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
    -- writefile adds newlines between lines; empty file = {}
    vim.fn.writefile(lines, dest)
  end

  local script = dir .. "/select.sh"
  local lines = {
    "#!/bin/sh",
    "set -e",
    'LEFT="$1"',
    'RIGHT="$2"',
    'CONTENT="' .. content_dir .. '"',
    'if [ -z "$RIGHT" ]; then exit 1; fi',
    'cd "$CONTENT"',
    "find . -type f | while IFS= read -r rel; do",
    '  rel="${rel#./}"',
    '  mkdir -p "$RIGHT/$(dirname "$rel")"',
    '  cp "$CONTENT/$rel" "$RIGHT/$rel"',
    "done",
  }
  vim.fn.writefile(lines, script)
  vim.fn.setfperm(script, "rwxr-xr-x")
  return script
end

---Non-interactive hunk split via a custom jj --tool.
---@param opts { cwd: string, revision?: string, message?: string, parallel?: boolean, files: table<string, string[]> }
---@return ProcessResult
function M.split_with_contents(opts)
  local jj = shell.resolve_jj()
  local script = write_tool_script(opts.files)
  local tool = "jujutsu-nvim-select"
  local paths = vim.tbl_keys(opts.files)
  table.sort(paths)

  local cmd = {
    jj,
    "--no-pager",
    "--color=never",
    "--config",
    string.format("merge-tools.%s.program=%s", tool, script),
    "--config",
    string.format('merge-tools.%s.edit-args=["$left","$right"]', tool),
    "split",
    "-i",
    "--tool",
    tool,
    "-r",
    opts.revision or "@",
    "-m",
    opts.message or table.concat(paths, ", "),
  }
  if opts.parallel then table.insert(cmd, "--parallel") end
  table.insert(cmd, "--")
  vim.list_extend(cmd, paths)

  return Process.await({
    cmd = cmd,
    cwd = opts.cwd,
    suppress_console = false,
  })
end

---Build selected file contents from parent + hunk indices.
---@param opts { cwd: string, revision?: string, path: string, file_diff: string[], hunk_indices: integer[] }
---@return string[]|nil, string|nil error
function M.selected_content(opts)
  local cli = require("jujutsu.jj.cli")
  local rev = opts.revision or "@"
  local parent = rev .. "-"
  local show = cli.file_show.revision(parent).paths(opts.path).call({
    cwd = opts.cwd,
    hidden = true,
    on_error = function() return false end,
  })
  local base_lines = {}
  if show.code == 0 then base_lines = show.stdout or {} end

  local all = hunks_mod.parse_hunks(opts.file_diff)
  local selected = {}
  local seen = {}
  for _, idx in ipairs(opts.hunk_indices) do
    if not seen[idx] and all[idx + 1] then
      seen[idx] = true
      selected[#selected + 1] = all[idx + 1]
    end
  end
  if #selected == 0 then return nil, "No hunks selected" end
  return hunks_mod.apply_hunks(base_lines, selected), nil
end

return M
