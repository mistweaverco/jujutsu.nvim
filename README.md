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
  annotate = { panel_height = 16 },
  disable_signs = false, -- gutter jjsigns (add/change/delete)
  signs = {
    item = { ">", "v" },
    section = { ">", "v" },
    add = { text = "┃" },
    change = { text = "┃" },
    delete = { text = "▁" },
    topdelete = { text = "▔" },
    changedelete = { text = "~" },
  },
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
jj.annotate()                          -- annotate current buffer at cursor line
jj.annotate({ path = "src/main.lua", line = 10 })
jj.review()                            -- pick an open PR/MR and review it
jj.review({ number = 15 })             -- open a specific PR/MR

-- Bindable action for your own keymaps:
vim.keymap.set("n", "<leader>jc", jj.action("change", "commit"))
vim.keymap.set("n", "<leader>jb", jj.annotate)
vim.keymap.set("n", "<leader>jr", jj.review)
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

## jjsigns

Gutter signs for working-copy line changes (like gitsigns, display-only).
Driven by `jj diff --git` against `@` parents. Refreshes on buffer enter /
write / focus and when `.jj` changes.

Disable with `disable_signs = true`, or customize glyphs via `signs.add` /
`signs.change` / `signs.delete` / `signs.topdelete` / `signs.changedelete`.

## Annotate

`jj file annotate` blame view: annotated lines on top, commits that touched the
file in a bottom panel (same idea as `dc`). Selecting a commit highlights its
lines in the annotate buffer.

- Magit: Diff popup `da` (file under cursor)
- Lua: `require("jujutsu").annotate()` (current buffer + cursor line)

## PR / MR review

Tuicr-inspired code review on top of the built-in DiffView (file panel +
side-by-side). Existing inline comments from the forge (GitHub/GitLab/…) are
loaded and shown as cyan overlays; your new local comments are yellow until
you submit or yank markdown.

**Providers**

| Provider | Transport | Credentials |
|----------|-----------|-------------|
| GitHub | `gh` | `gh auth login` |
| GitLab | `glab` | `glab auth login` |
| Codeberg / Forgejo | `curl` REST | Prompted per host and stored under `stdpath("data")/jujutsu/credentials.json`, or `FORGEJO_TOKEN` / `CODEBERG_TOKEN` / `forge.forgejo.token` |
| Bitbucket Cloud | `curl` REST | Prompted per workspace (username + token) and stored in the same file, or `BITBUCKET_USER` + `BITBUCKET_TOKEN` / `forge.bitbucket.*` |

On HTTP 401/403, review asks whether to supply new credentials or delete the stored ones.

**Entry points**

- Diff popup `dR` (Review PR/MR)
- `require("jujutsu").review()` / `.review({ number = 15 })`

**Review keymaps** (in DiffView review mode)

| Key | Action |
|-----|--------|
| `c` | Comment at cursor line |
| `C` | File comment |
| visual `c` | Range comment |
| `;c` | Review-level comment |
| `e` / `i` | Edit unsubmitted comment at cursor |
| `m` / `M` | Next / previous comment |
| `r` | Toggle file reviewed (panel) |
| `y` | Yank structured markdown |
| `S` | Submit (Comment / Approve / Request changes; Draft on GitHub only) |
| `?` | Help |

Sessions persist under `stdpath("data")/jujutsu/reviews/`. Bitbucket / Forgejo credentials persist under `stdpath("data")/jujutsu/credentials.json`.

```lua
forge = {
  pr_integration = true,
  review = { enabled = true },
  bitbucket = { user = vim.env.BITBUCKET_USER, token = vim.env.BITBUCKET_TOKEN },
  forgejo = { token = vim.env.CODEBERG_TOKEN },
  hosts = {}, -- e.g. ["git.example.com"] = "gitlab"
},
```

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
| `da` | Annotate file under cursor (`jj file annotate` + file history panel) |
| `dr` | Range side-by-side diff |
| `dR` | Review open PR/MR (forge) |
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
    -- default jujutsu lualine widget
    lualine_a = { "mode", "jujutsu" },
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
