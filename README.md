<div align="center">

![jujutsu.nvim Logo](logo.svg)

# jujutsu.nvim

A `Magit`-style [`Jujutsu (jj)`](https://github.com/jj-vcs/jj)
interface for Neovim.

---

Inspired by [`Neogit`](https://github.com/neogitorg/neogit)
rewritten without required plugin dependencies.

![jujutsu.nvim promo image](assets/jujutsu.nvim-opengraph-image.png)

</div>

## Recent Changes

See [`CHANGELOG.md`](CHANGELOG.md) for a full list of changes.

## Requirements

- Neovim 0.10+
- [`jj`](https://jj-vcs.github.io/jj/) on your `PATH`

**No required Neovim plugins.** Optional:

The build-in diff viewer should work perfectly fine,
but if you absolutely must, you can install one of the following diff viewers and
pick it in the setup:

-  [`diffview.nvim`](https://github.com/sindrets/diffview.nvim) or
- [`codediff.nvim`](https://github.com/esmuellert/codediff.nvim)

You can use one of the following fuzzy finders for
the file history and change history popups.
If none are installed, the built-in picker will be used.

- `Telescope`
- `fzf-lua`
- `mini.pick`
- `snacks.nvim`

## Installation (`lazy.nvim`)

```lua
{
  "mistweaverco/jujutsu.nvim",
  lazy = true,
  -- optional deps:
  -- dependencies = { "sindrets/diffview.nvim", "ibhagwan/fzf-lua" },
  keys = {
    {
      "<leader>gg",
      function()
        require("jujutsu").open()
      end,
      desc = "Jujutsu",
    },
  },
  opts = {}, -- passed to setup()
}
```

There are **no** user commands (`:Jujutsu` isn't registered).
Use the Lua API.

## Lua API

```lua
local jj = require("jujutsu")

jj.setup({
  kind = "tab", -- tab | split | vsplit | floating | replace | auto | ...
  mappings = {
    -- set a key to false to disable a default
    status = {
      ["q"] = "Close",
      ["x"] = "Discard",
    },
    popup = {
      ["c"] = "ChangePopup",
      ["b"] = "BookmarkPopup",
    },
  },
  integrations = {
    -- nil = auto-detect, true = force, false = disable
    telescope = nil,
    fzf_lua = nil,
    mini_pick = nil,
    snacks = nil,
    diffview = nil,
    codediff = nil,
  },
  diff_viewer = nil, -- "diffview" | "codediff" | nil = auto
  file_history = { limit = 200, panel_height = 16 },
  forge = { pr_integration = true },
  commit_date_format = "absolute", -- "absolute" | "relative" | strftime (e.g. "%Y-%m-%d %H:%M")
  log_date_format = "absolute",
})

jj.open()                              -- status buffer
jj.open({ kind = "split" })
jj.open({ cwd = vim.fn.expand("%:p:h") })
jj.open({ "change" })                  -- open a popup by name
jj.close()
jj.refresh()

-- Bindable action for your own keymaps:
vim.keymap.set("n", "<leader>jc", jj.action("change", "commit"))
```

### Popup Names

- `help`
- `change`
- `bookmark`
- `diff`
- `fetch`
- `log`
- `remote`
- `push`
- `rebase`
- `squash`
- `undo`
- `workspace`

## Status Buffer

Shows working-copy / parent headers,
conflicts,
file changes (inline diffs via `<Tab>`),
recent commits, and bookmarks.

### Default Popups (Lowercase)


| Key | Popup |
|-----|--------|
| `?` | Help |
| `b` | Bookmark |
| `c` | Change |
| `d` | Diff |
| `dd` | Working-copy side-by-side diff |
| `dc` | Change history (file under cursor → that path; revision → focus that change; else repo-wide) |
| `dr` | Range side-by-side diff |
| `dt` | Trunk/main/master..@ side-by-side diff |
| `f` | Fetch |
| `l` | Log |
| `m` | Remote |
| `p` | Push |
| `r` | Rebase |
| `s` | Squash |
| `u` | Undo |
| `w` | Workspace |


### Context Actions (Uppercase / Misc)


| Key | Action |
|-----|--------|
| `D` | Describe change under cursor |
| `E` | Edit change under cursor |
| `O` | New change on revision |
| `B` | New change before |
| `F` | Forget / track bookmark |
| `P` | Split change (opens split popup; visual-select hunks then `P`→`f`) |
| `S` | Open `--stat` view for change under cursor |
| `o` | Open in browser (forge) |
| `x` | Discard file / abandon change / delete bookmark |
| `q` | Close |
| `<C-r>` | Refresh |
| `<Tab>` | Toggle section / file diff / recent commit / bookmark history |
| `<CR>` | Open file / commit |

In the log view, `S` opens the `--stat` view and `P` opens the split popup for the
revision under the cursor.

Remap with:

```lua
require("jujutsu").setup({
  mappings = {
    status = { ["P"] = "Split" },
    log_view = { ["P"] = "Split" },
    -- or bind a popup key: popup = { ["P"] = "SplitPopup" },
  },
  stat_view = { kind = "vsplit" }, -- or "tab" / "split"
})
```

## `Lualine` Integration

> [!NOTE]
> oh-my-posh-style, with an ahead counter when
> you are not on the bookmark.

Colored `+` / `~` / `-` **line** counts for the working-copy diff (repo-wide),
plus the working-copy change id (prefixed with ``) and the **closest**
bookmark(s) on ancestors of `@`.

Uses the color API of `lualine`, so the **section background is preserved**.
Counts refresh on write / `cwd` change / focus (not every buffer switch).

**Important:** `components()` returns a *list* of components. Flatten it into the
section - do not put the list itself as one entry.

```lua
require("lualine").setup({
  sections = {
    -- jj widgets first, then your items:
    lualine_b = require("jujutsu.lualine").prepend({ "branch" }),

    -- your items first, then jj widgets:
    lualine_x = require("jujutsu.lualine").append({
      "kulala",
      "encoding",
      "fileformat",
      "filetype",
    }),

    -- or flatten manually:
    -- lualine_b = vim.list_extend({ "branch" }, require("jujutsu.lualine").components()),

    -- single plain component (one color, safe as `{ ... }`):
    -- lualine_b = { require("jujutsu.lualine").component() },
  },
})
```

Helpers: `require("jujutsu.lualine").rev()`, `.bookmark()`, `.diff()`, `.status()`.

Override any mapping in `setup({ mappings = ... })`, or set `use_default_keymaps = false` and define all yourself.

## License

See the [LICENSE](LICENSE) file for details.
