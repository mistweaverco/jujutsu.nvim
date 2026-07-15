local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local common = require("jujutsu.popups.common")
local finder = require("jujutsu.finder")
local notify = require("jujutsu.notify")

local M = {}

function M.add(popup)
  local root = common.root(popup)
  vim.ui.input({ prompt = "Remote name: " }, function(name)
    if not name or name == "" then return end
    vim.ui.input({ prompt = "Remote URL: " }, function(url)
      if url and url ~= "" then
        cli.git_remote_add.args(name, url).call({ cwd = root, hidden = false })
        notify.info("Added remote " .. name)
        require("jujutsu").refresh()
      end
    end)
  end)
end

function M.remove(popup)
  local root = common.root(popup)
  local remote = finder.pick_remote({ prompt = "Remove remote", cwd = root })
  if remote then common.run(popup, cli.git_remote_remove.args(remote)) end
end

function M.rename(popup)
  local root = common.root(popup)
  local remote = finder.pick_remote({ prompt = "Rename remote", cwd = root })
  if not remote then return end
  vim.ui.input({ prompt = "New name: ", default = remote }, function(name)
    if name and name ~= "" then
      cli.git_remote_rename.args(remote, name).call({ cwd = root, hidden = false })
      require("jujutsu").refresh()
    end
  end)
end

function M.list(popup)
  local root = common.root(popup)
  local res = cli.git_remote_list.call({ cwd = root, hidden = true })
  local buf = Buffer.create("jujutsu://remotes", "jujutsu-log")
  Buffer.open(buf, "split")
  Buffer.render(buf, #res.stdout > 0 and res.stdout or { "(no remotes)" })
  vim.keymap.set("n", "q", function() Buffer.close(buf) end, { buffer = buf.bufnr, silent = true })
end

return M
