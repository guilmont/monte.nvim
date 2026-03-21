# monte.nvim

A minimal Neovim setup with VS Code-like editing, solid LSP defaults, and custom workflows for Git, Perforce, and async command execution.

## Features

- VS Code-like editing keybindings for moving lines and word-wise navigation
- Mason + lspconfig based LSP setup with simple defaults
- GitHub Copilot with `Alt+Enter` accept
- Telescope for files, buffers, and grep
- Neo-tree for file browsing
- Custom Git review window with diff, stage toggle, commit, and `lazygit`
- Custom Perforce changelist manager with shelving and depot diffs
- Async `:Run` command runner with parsed output and jump-to-location support
- Carbonfox theme, mini.statusline, and trim-on-save whitespace cleanup

## Prerequisites

- Neovim 0.9+
- Git
- A C compiler or `make` for `telescope-fzf-native`
- Node.js for Copilot and some language servers
- Optional: `ripgrep` for Telescope live grep
- Optional: `p4` for Perforce support
- Optional: `lazygit` for Git TUI integration
- Optional: Nerd Font if you want icons

## Installation

```bash
mv ~/.config/nvim ~/.config/nvim.backup

git clone https://github.com/guilmont/monte.nvim.git ~/.config/nvim

nvim
```

On first launch, `lazy.nvim` bootstraps itself and installs plugins automatically.

## First-time setup

1. Open `nvim`
2. Run `:Mason`
3. Install the language servers you want
4. Run `:LspSetupInstalled` or restart Neovim
5. Run `:Copilot setup`

## Keybindings

### General

| Mode | Key | Action |
|------|-----|--------|
| - | `Space` | Leader key |
| `n` | `\` | Reveal current file in Neo-tree |
| `n` | `Ctrl+\` | Close Neo-tree |
| `n` | `Ctrl+p` | Find files |
| `n` | `Ctrl+b` | List buffers |
| `n` | `Ctrl+g` | Live grep |
| `n` | `Alt+v` | Blockwise visual mode |
| `n` | `Esc` | Clear search highlights |
| `n` | `<leader>t` | Open terminal in current window |

### Editing

| Mode | Key | Action |
|------|-----|--------|
| `n` `i` `v` | `Alt+j` / `Alt+Down` | Move line/block down |
| `n` `i` `v` | `Alt+k` / `Alt+Up` | Move line/block up |
| `n` `v` `i` | `Alt+Right` | Jump forward by word |
| `n` `v` `i` | `Alt+Left` | Jump backward by word |
| `n` `i` | `Alt+Backspace` | Delete previous word |
| `n` `i` | `Alt+Delete` | Delete next word |

### LSP

| Mode | Key | Action |
|------|-----|--------|
| `n` | `<leader>ld` | Goto definition |
| `n` | `<leader>lD` | Goto declaration |
| `n` | `<leader>lr` | References |
| `n` | `<leader>li` | Goto implementation |
| `n` | `<leader>lh` | Hover |
| `n` | `<leader>ls` | Signature help |
| `n` | `<leader>lR` | Rename |
| `n` | `<leader>la` | Code action |
| `n` | `<leader>lF` | Format buffer |
| `n` | `<leader>lS` | Workspace symbols |
| `n` | `<leader>lwA` | Add workspace folder |
| `n` | `<leader>lwR` | Remove workspace folder |
| `n` | `<leader>lwl` | List workspace folders |
| `n` | `<leader>lx` | Line diagnostics |
| `n` | `<leader>lX` | Restart LSP clients |
| `n` | `<leader>lH` | Toggle inlay hints |
| `n` | `[d` | Previous diagnostic |
| `n` | `]d` | Next diagnostic |

### Completion

| Mode | Key | Action |
|------|-----|--------|
| `i` | `Ctrl+Space` | Trigger completion |
| `i` | `Enter` | Confirm selected completion |

Completion is manual by design. `Tab` is reserved for Copilot.

### Copilot

| Mode | Key | Action |
|------|-----|--------|
| `i` | `Alt+Enter` | Accept suggestion |
| `i` | `Alt+]` | Next suggestion |
| `i` | `Alt+[` | Previous suggestion |
| `i` | `Alt+d` | Dismiss suggestion |
| `i` | `Alt+\` | Trigger suggestion |

### Git

| Mode | Key | Action |
|------|-----|--------|
| - | `:GitWindow` | Open Git review window |
| - | `:GitDiff` | Diff current file against `HEAD` |
| - | `:GitLazyGit` | Open `lazygit` in repo root |
| `n` | `<leader>gs` | Open Git review window |
| `n` | `<leader>gd` | Diff current file against `HEAD` |
| `n` | `<leader>gg` | Open `lazygit` |

#### Git review window

| Mode | Key | Action |
|------|-----|--------|
| `n` | `Enter` | Open selected file |
| `n` | `d` | Diff selected file |
| `n` | `r` | Revert selected file |
| `n` | `s` | Toggle stage / unstage |
| `n` | `c` | Commit staged changes |
| `n` | `g` | Open `lazygit` |
| `n` | `q` | Close Git window |

#### Git diff view

| Mode | Key | Action |
|------|-----|--------|
| `n` | `[` | Previous hunk |
| `n` | `]` | Next hunk |
| `n` | `r` | Revert current hunk from `HEAD` |
| `n` | `q` | Close base/original side only |
| `n` | `Q` | Close both diff windows |

### Perforce

| Mode | Key | Action |
|------|-----|--------|
| - | `:P4Window` | Open Perforce changelist window |
| - | `:P4Edit` | Open current file for edit |
| - | `:P4Add` | Add current file |
| - | `:P4Revert` | Revert current file |
| - | `:P4Delete` | Mark current file for delete |
| - | `:P4Rename` | Move/rename current file |
| - | `:P4Diff` | Diff current file |
| `n` | `<leader>ps` | Open Perforce changelist window |
| `n` | `<leader>pe` | Edit current file |
| `n` | `<leader>pa` | Add current file |
| `n` | `<leader>pr` | Revert current file |
| `n` | `<leader>pD` | Delete current file |
| `n` | `<leader>pR` | Move/rename current file |
| `n` | `<leader>pd` | Diff current file |

#### Perforce changelist window

| Mode | Key | Action |
|------|-----|--------|
| `n` | `Enter` | Open file / edit CL / toggle shelf |
| `n` | `d` | Diff selected file |
| `n` | `r` | Revert file or changelist |
| `n` | `m` | Move file to another changelist |
| `n` | `s` | Shelve file or changelist |
| `n` | `u` | Unshelve file or changelist |
| `n` | `D` | Delete file, shelf, or changelist |
| `n` | `q` | Close Perforce window |

#### Perforce diff view

| Mode | Key | Action |
|------|-----|--------|
| `n` | `[` | Previous hunk |
| `n` | `]` | Next hunk |
| `n` | `r` | Revert current hunk from depot |
| `n` | `q` | Close base/original side only |
| `n` | `Q` | Close both diff windows |

### Command runner

| Mode | Key | Action |
|------|-----|--------|
| - | `:Run <command>` | Run command asynchronously |
| - | `:Run` | Prompt for a command |
| `n` | `<leader>r` | Start `:Run` command entry |

#### Run output window

| Mode | Key | Action |
|------|-----|--------|
| `n` | `Enter` | Open file location under cursor |
| `n` | `[` | Previous parsed location |
| `n` | `]` | Next parsed location |
| `n` | `r` | Re-run last command |
| `n` | `k` | Kill running command |
| `n` | `q` | Close output window |

## Project structure

```text
.
├── init.lua
├── lazy-lock.json
├── lua/
│   ├── config/
│   │   ├── autocmds.lua
│   │   ├── keymaps.lua
│   │   └── options.lua
│   ├── custom/
│   │   ├── diffsplit.lua
│   │   ├── git.lua
│   │   ├── perforce.lua
│   │   ├── run.lua
│   │   └── utils.lua
│   └── plugins/
│       ├── colors.lua
│       ├── completion.lua
│       ├── copilot.lua
│       ├── guess-indent.lua
│       ├── lsp.lua
│       ├── neo-tree.lua
│       ├── telescope.lua
│       ├── treesitter.lua
│       └── ui.lua
└── README.md
```

## Plugins

- [lazy.nvim](https://github.com/folke/lazy.nvim)
- [nightfox.nvim](https://github.com/EdenEast/nightfox.nvim)
- [mini.nvim](https://github.com/echasnovski/mini.nvim)
- [guess-indent.nvim](https://github.com/NMAC427/guess-indent.nvim)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- [mason.nvim](https://github.com/mason-org/mason.nvim)
- [mason-lspconfig.nvim](https://github.com/mason-org/mason-lspconfig.nvim)
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
- [LuaSnip](https://github.com/L3MON4D3/LuaSnip)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [telescope-fzf-native.nvim](https://github.com/nvim-telescope/telescope-fzf-native.nvim)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)
- [copilot.vim](https://github.com/github/copilot.vim)

Git, Perforce, diff handling, and the command runner are implemented in the `lua/custom/` modules rather than through an extra plugin.

## Configuration notes

### LSP

Install servers through `:Mason`. This config auto-wires Mason-installed servers on startup.

If you want server-specific tweaks, edit [lua/plugins/lsp.lua](lua/plugins/lsp.lua).

### Theme

The theme is configured in [lua/plugins/colors.lua](lua/plugins/colors.lua). Change `carbonfox` there if you want a different Nightfox variant.

## Troubleshooting

### LSP

- Check `:LspInfo`
- Check `:LspLog`
- After installing servers in Mason, run `:LspSetupInstalled` or restart Neovim

### Copilot

- Check `:Copilot status`
- Run `:Copilot setup`
- Try `:Copilot restart`

### Telescope grep

- Install `ripgrep`
- Make sure you are inside the project you expect to search

### Perforce

- Verify `p4` is installed
- Check `p4 info`
- Check `p4 login -s`
- Verify `P4PORT`, `P4CLIENT`, and `P4USER`

### Git / lazygit

- Verify Git root detection with `git rev-parse --show-toplevel`
- Verify `lazygit` is installed if you want the TUI launcher

## Notes

- Leader key is `Space`
- `Tab` is reserved for Copilot
- Completion is manual
- Trailing whitespace and final blank lines are trimmed on save
- Indentation defaults to 4 spaces and is refined per file by `guess-indent.nvim`
- Git and Perforce are both supported through separate custom workflows

## License

MIT
