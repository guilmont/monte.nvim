# monte.nvim

A minimal, fast Neovim setup with VS Code-like ergonomics and powerful development tools.

## ✨ Features

- **VS Code-like cursor behavior** - Familiar keybindings for moving lines, words, and multicursor editing
- **Powerful LSP** - Code intelligence for C/C++, Rust, Python, JavaScript/TypeScript, and Lua
- **GitHub Copilot** - AI-powered code completion
- **Fuzzy finding** - Quick file/buffer navigation and project-wide search
- **File explorer** - Neo-tree with intuitive navigation
- **Command runner** - Emacs-style async compilation with clickable error parsing
- **Smart indentation** - Auto-detects tab/space preferences per file
- **Clean UI** - Carbonfox theme with statusline and minimal distractions

## 🚀 Quick Start

### Prerequisites

- Neovim ≥ 0.9
- Git
- A C compiler (for Telescope fzf-native)
- Node.js (for Copilot and some LSP servers)

### Installation

```bash
# Backup your existing config
mv ~/.config/nvim ~/.config/nvim.backup

# Clone this config
git clone https://github.com/guilmont/monte.nvim ~/.config/nvim

# Start Neovim - plugins will install automatically
nvim
```

### First-time Setup

1. **LSP servers install automatically** on first launch
2. **Set up Copilot**: Run `:Copilot setup` and follow the authentication flow
3. **That's it!** Start coding

## ⌨️ Keybindings

### General

| Key | Action |
|-----|--------|
| `\` | Toggle file explorer (Neo-tree) |
| `Ctrl+p` | Find files |
| `Ctrl+b` | Find buffers |
| `<leader>fg` | Grep search (live grep) |
| `<leader>` is **Space** by default |

### Cursor & Editing (VS Code-like)

| Key | Action |
|-----|--------|
| `Alt+j` / `Alt+↓` | Move line/block down |
| `Alt+k` / `Alt+↑` | Move line/block up |
| `Shift+Alt+j` / `Shift+Alt+↓` | Duplicate line/block down |
| `Shift+Alt+k` / `Shift+Alt+↑` | Duplicate line/block up |
| `Ctrl+→` | Jump word forward |
| `Ctrl+←` | Jump word backward |
| `Ctrl+Backspace` | Delete word backward |
| `Ctrl+Delete` | Delete word forward |
| `Ctrl+d` | Add cursor at next match (multicursor) |
| `gg` | Go to top of file |
| `G` | Go to bottom of file |

### LSP (Code Intelligence)

| Key | Action |
|-----|--------|
| `gd` | Go to definition |
| `gr` | Find references |
| `K` | Show hover documentation |
| `<leader>rn` | Rename symbol |
| `<leader>ca` | Code actions |
| `<leader>e` | Show diagnostic/error message |
| `]d` | Next diagnostic |
| `[d` | Previous diagnostic |

### Completion

| Key | Action |
|-----|--------|
| `Ctrl+Space` | Trigger completion |
| `Enter` | Confirm selection |
| `Tab` / `Shift+Tab` | Navigate completion (or accept Copilot) |
| `Ctrl+n` / `Ctrl+p` | Next/previous item |
| `Ctrl+j` / `Ctrl+k` | Next/previous item (alternative) |

### GitHub Copilot

| Key | Action |
|-----|--------|
| `Tab` | Accept suggestion |
| `Alt+]` | Next suggestion |
| `Alt+[` | Previous suggestion |
| `Ctrl+e` | Dismiss suggestion |
| `Alt+\` | Manually trigger |

### Command Runner (`:Run`)

| Key | Action |
|-----|--------|
| `:Run <command>` | Run command async with live output |
| `:Run` (no args) | Prompt for command with completion |
| `Enter` (in output) | Open file at line under cursor |
| Click (in output) | Same as Enter - jump to error |
| `q` (in output) | Close output window |

Examples:
- `:Run make`
- `:Run cargo build`
- `:Run g++ main.cpp -o a.out`
- `:Run npm test`

### Neo-tree (File Explorer)

| Key | Action |
|-----|--------|
| `Enter` / `l` | Open file/directory |
| `h` / `Backspace` | Close directory / go to parent |
| `a` | Add file/directory |
| `d` | Delete |
| `r` | Rename |
| `y` | Copy |
| `x` | Cut |
| `p` | Paste |
| `H` | Toggle hidden files |
| `?` | Show help |

## 🔧 Configuration Structure

```
~/.config/nvim/
├── init.lua              # Entry point, editor options
├── lazy-lock.json        # Plugin version lock
└── lua/plugins/
    ├── colors.lua        # Theme (Carbonfox)
    ├── completion.lua    # nvim-cmp setup
    ├── copilot.lua       # GitHub Copilot
    ├── cursor.lua        # VS Code-like cursor keymaps
    ├── guess-indent.lua  # Auto-detect indentation
    ├── lsp.lua          # Language servers
    ├── neo-tree.lua     # File explorer
    ├── run.lua          # Async command runner
    ├── telescope.lua    # Fuzzy finder
    ├── treesitter.lua   # Syntax highlighting
    └── ui.lua           # Statusline & trim whitespace
```

## 📦 Plugins

- **lazy.nvim** - Fast plugin manager
- **telescope.nvim** - Fuzzy finder
- **nvim-treesitter** - Better syntax highlighting
- **nvim-lspconfig** + **mason.nvim** - LSP management
- **nvim-cmp** - Completion engine
- **neo-tree.nvim** - File explorer
- **nightfox.nvim** - Color scheme
- **copilot.vim** - GitHub Copilot
- **vim-visual-multi** - Multicursor support
- **guess-indent.nvim** - Auto-detect tabs/spaces
- **mini.nvim** - Statusline & utilities

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
  -- Add your server here:
  gopls = {},  -- Go
  -- etc.
}
```

### Adjust Command Runner Output Width

Edit `lua/plugins/run.lua` and change the `60` in `nvim_win_set_width(win, 60)` to your preferred width.

## 🐛 Troubleshooting

**LSP not working?**
- Check `:Mason` to see if servers are installed
- Run `:LspInfo` in a file to check LSP status

**Copilot not suggesting?**
- Run `:Copilot status` to check authentication
- Run `:Copilot setup` to re-authenticate

**Telescope not finding files?**
- Make sure you're in a project directory
- Check that `ripgrep` is installed for live grep

**Completion not working?**
- Make sure the LSP server is running (`:LspInfo`)
- Try manually triggering with `Ctrl+Space`

## 📝 Notes

- Leader key is `Space`
- Auto-saves trim trailing whitespace and final blank lines
- Indentation defaults to 4 spaces but auto-detects per file
- Terminal is `zsh` by default (change in `init.lua` if needed)

## 🤝 Contributing

This is a personal configuration, but feel free to fork and adapt to your needs!

## 📄 License

MIT
