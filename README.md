# monte.nvim

A minimal, fast Neovim setup with VS Code-like ergonomics and powerful development tools.

## ✨ Features

- **VS Code-like cursor behavior** - Familiar keybindings for moving lines, words, and word-wise editing
- **Powerful LSP** - Code intelligence for C/C++, Rust, Python, JavaScript/TypeScript, and Lua
- **GitHub Copilot** - AI-powered code completion
- **Fuzzy finding** - Quick file/buffer navigation and project-wide search with Telescope
- **File explorer** - Neo-tree with intuitive navigation
- **Perforce integration** - Full P4 workflow with visual changelist management
- **Command runner** - Async compilation with live output and clickable error parsing
- **Git integration** - Vim-fugitive for Git operations
- **Smart indentation** - Auto-detects tab/space preferences per file
- **Clean UI** - Carbonfox theme with statusline and minimal distractions

## 🚀 Quick Start

### Prerequisites

- Neovim ≥ 0.9
- Git
- A C compiler (for Telescope fzf-native)
- Node.js (for Copilot and some LSP servers)
- [Optional] Perforce CLI (`p4`) if using Perforce features

### Installation

```bash
# Backup your existing config
mv ~/.config/nvim ~/.config/nvim.backup

# Clone this config
git clone https://github.com/guilmont/monte.nvim.git ~/.config/nvim

# Start Neovim - plugins will install automatically
nvim
```

### First-time Setup

1. **LSP servers install automatically** on first launch
2. **Set up Copilot**: Run `:Copilot setup` and follow the authentication flow
3. **That's it!** Start coding

## ⌨️ Keybindings

### General

| Mode | Key | Action |
|------|-----|--------|
| - | `Space` | Leader key |
| `n` | `\` | Toggle file explorer (Neo-tree) |
| `n` | `Ctrl+\` | Close file explorer |
| `n` | `Ctrl+p` | Find files |
| `n` | `Ctrl+b` | Find buffers |
| `n` | `Ctrl+g` | Grep search (live grep) |
| `n` | `Alt+v` | Start V-block selection (WSL-friendly) |

### Cursor & Editing (VS Code-like)

| Mode | Key | Action |
|------|-----|--------|
| `n` `i` `v` | `Alt+j` / `Alt+↓` | Move line/block down |
| `n` `i` `v` | `Alt+k` / `Alt+↑` | Move line/block up |
| `n` `v` | `Ctrl+→` | Jump word forward |
| `n` `v` | `Ctrl+←` | Jump word backward |
| `i` | `Ctrl+Backspace` | Delete word backward |
| `i` | `Ctrl+Delete` | Delete word forward |
| `n` | `gg` | Go to top of file |
| `n` | `G` | Go to bottom of file |

### LSP (Code Intelligence)

| Mode | Key | Action |
|------|-----|--------|
| `n` | `gd` | Go to definition |
| `n` | `gr` | Find references |
| `n` | `K` | Show hover documentation |
| `n` | `<leader>rn` | Rename symbol |
| `n` | `<leader>ca` | Code actions |
| `n` | `]d` | Next diagnostic |
| `n` | `[d` | Previous diagnostic |

### Completion

| Mode | Key | Action |
|------|-----|--------|
| `i` | `Ctrl+Space` | Trigger completion |
| `i` | `Enter` | Confirm selection |
| `i` | `Tab` | Next item (or accept Copilot) |
| `i` | `Shift+Tab` | Previous item |
| `i` | `Ctrl+e` | Abort completion (or dismiss Copilot) |

### GitHub Copilot

| Mode | Key | Action |
|------|-----|--------|
| `i` | `Tab` | Accept suggestion |
| `i` | `Alt+]` | Next suggestion |
| `i` | `Alt+[` | Previous suggestion |
| `i` | `Ctrl+e` | Dismiss suggestion |
| `i` | `Alt+\` | Manually trigger |

### Git (vim-fugitive)

| Mode | Key | Action |
|------|-----|--------|
| - | `:Git` | Git status |
| `n` | `<leader>gs` | Git status |
| `n` | `<leader>gd` | Git vertical diff |

### Perforce

| Mode | Key | Action |
|------|-----|--------|
| `n` | `<leader>ps` | Show opened files (changelist manager) |
| `n` | `<leader>pe` | Edit current file |
| `n` | `<leader>pa` | Add current file |
| `n` | `<leader>pr` | Revert current file |
| `n` | `<leader>px` | Delete current file |
| `n` | `<leader>pm` | Move/rename current file |
| `n` | `<leader>pd` | Diff current file |

#### Perforce Changelist Manager (`:P4Opened` or `<leader>ps`)

| Mode | Key | Action |
|------|-----|--------|
| `n` | `Enter` | Open file / Edit CL description / Toggle shelf |
| `n` | `d` | Show diff |
| `n` | `r` | Revert file or CL |
| `n` | `m` | Move file to different CL |
| `n` | `s` | Shelve file or CL |
| `n` | `u` | Unshelve file or CL |
| `n` | `D` | Delete file, CL, or shelf |
| `n` | `N` | Create new changelist |
| `n` | `q` / `Esc` | Close window |

### Command Runner (`:Run`)

| Mode | Key | Action |
|------|-----|--------|
| - | `:Run <command>` | Run command async with live output |
| - | `:Run` (no args) | Prompt for command with completion |
| `n` | `Enter` (in output) | Open file at line under cursor |
| `n` | Click (in output) | Same as Enter - jump to error |
| `n` | `q` (in output) | Close output window |

Examples:
- `:Run make`
- `:Run cargo build`
- `:Run g++ main.cpp -o a.out`
- `:Run npm test`

### Neo-tree (File Explorer)

| Mode | Key | Action |
|------|-----|--------|
| `n` | `\` | Toggle/reveal Neo-tree |
| `n` | `Ctrl+\` | Close Neo-tree |
| `n` | `Enter` / `l` | Open file/directory |
| `n` | `h` / `Backspace` | Close directory / go to parent |
| `n` | `a` | Add file/directory |
| `n` | `d` | Delete |
| `n` | `r` | Rename |
| `n` | `y` | Copy |
| `n` | `x` | Cut |
| `n` | `p` | Paste |
| `n` | `H` | Toggle hidden files |
| `n` | `?` | Show help |

## 🔧 Configuration Structure

```
~/.config/nvim/
├── init.lua                   # Entry point, bootstraps lazy.nvim
├── lazy-lock.json            # Plugin version lock
├── lua/
│   ├── config/
│   │   ├── options.lua       # Vim options and settings
│   │   ├── keymaps.lua       # Core keymaps (VS Code-like)
│   │   ├── autocmds.lua      # Autocommands (yank highlight)
│   │   ├── perforce.lua      # Perforce integration
│   │   └── run.lua           # Async command runner
│   └── plugins/
│       ├── colors.lua        # Theme (Carbonfox)
│       ├── completion.lua    # nvim-cmp setup
│       ├── copilot.lua       # GitHub Copilot
│       ├── fugitive.lua      # Git integration
│       ├── guess-indent.lua  # Auto-detect indentation
│       ├── lsp.lua           # Language servers
│       ├── neo-tree.lua      # File explorer
│       ├── telescope.lua     # Fuzzy finder
│       ├── treesitter.lua    # Syntax highlighting
│       └── ui.lua            # Statusline & trim whitespace
```

## 📦 Plugins

- **lazy.nvim** - Fast plugin manager
- **telescope.nvim** + **telescope-fzf-native** - Fuzzy finder
- **nvim-treesitter** - Better syntax highlighting
- **nvim-lspconfig** + **mason.nvim** + **mason-lspconfig** + **mason-tool-installer** - LSP management
- **nvim-cmp** + **cmp-nvim-lsp** + **LuaSnip** - Completion engine
- **neo-tree.nvim** + **nui.nvim** + **nvim-web-devicons** - File explorer
- **nightfox.nvim** - Color scheme (Carbonfox variant)
- **copilot.vim** - GitHub Copilot
- **vim-fugitive** - Git integration
- **guess-indent.nvim** - Auto-detect tabs/spaces
- **mini.nvim** - Statusline & utilities (trailspace trimming)

## 🛠️ Customization

### Change Theme

Edit `lua/plugins/colors.lua` and change `carbonfox` to another nightfox variant:
- `nightfox`, `dayfox`, `dawnfox`, `duskfox`, `nordfox`, `terafox`, `carbonfox`

### Add More LSP Servers

Edit `lua/plugins/lsp.lua` and add to the `servers` table:

```lua
local servers = {
  clangd = {},
  rust_analyzer = {},
  pyright = {},
  ts_ls = {},
  lua_ls = { settings = { Lua = { completion = { callSnippet = 'Replace' } } } },
  -- Add your server here:
  gopls = {},  -- Go
  -- etc.
}
```

### Adjust Command Runner Output Width

Edit `lua/config/run.lua` and change the `60` in `nvim_win_set_width(win, 60)` to your preferred width.

### Configure Perforce Client

The Perforce integration works with your existing P4 environment. Make sure you have:
- `p4` command available in your PATH
- A valid P4CLIENT environment variable or p4 config
- Logged in to your Perforce server (`p4 login`)

## 🐛 Troubleshooting

**LSP not working?**
- Check `:Mason` to see if servers are installed
- Run `:LspInfo` in a file to check LSP status

**Copilot not suggesting?**
- Run `:Copilot status` to check authentication
- Run `:Copilot setup` to re-authenticate

**Telescope not finding files?**
- Make sure you're in a project directory
- Check that `ripgrep` is installed for live grep: `brew install ripgrep` (macOS) or `apt install ripgrep` (Linux)

**Completion not working?**
- Make sure the LSP server is running (`:LspInfo`)
- Try manually triggering with `Ctrl+Space`

**Perforce commands failing?**
- Verify `p4` is in your PATH: `which p4`
- Check your P4 connection: `p4 info`
- Ensure you're logged in: `p4 login`

**Neo-tree or Telescope icons not showing?**
- Make sure you have a Nerd Font installed and selected in your terminal
- Set `vim.g.have_nerd_font = true` in `init.lua` (should be default)

## 📝 Notes

- Leader key is `Space`
- Auto-saves trim trailing whitespace and final blank lines
- Indentation defaults to 4 spaces but auto-detects per file
- Line numbers, cursorline, and signcolumn are enabled by default
- Clipboard syncs with system clipboard
- Undo history is persistent across sessions
- Case-insensitive search (unless capital letters are used)
- Perforce integration provides a complete changelist manager with shelving support
- Git and Perforce can coexist - use vim-fugitive for Git, custom P4 commands for Perforce

## 🤝 Contributing

This is a personal configuration, but feel free to fork and adapt to your needs!

## 📄 License

MIT
