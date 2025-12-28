# monte.nvim

A minimal, fast Neovim setup with VS Code-like ergonomics and powerful development tools.

## ✨ Features

- **VS Code-like keybindings** - Familiar shortcuts for moving lines, word navigation, and editing (`Alt+j/k`, `Alt+←/→`, `Alt+Backspace/Delete`)
- **Powerful LSP** - Code intelligence via nvim-lspconfig + Mason for any language
- **GitHub Copilot** - AI-powered code completion with `Tab` to accept
- **Fuzzy finding** - Quick file/buffer navigation (`Ctrl+p`, `Ctrl+b`) and project-wide search (`Ctrl+g`) with Telescope
- **File explorer** - Neo-tree with intuitive navigation (`\` to toggle)
- **Perforce integration** - Full P4 workflow with visual changelist manager, shelving, and diffing
- **Command runner** - Async command execution (`:Run`) with live output, error parsing, and clickable file locations
- **Git integration** - Vim-fugitive for Git operations
- **Smart indentation** - Auto-detects tab/space preferences per file (guess-indent.nvim)
- **Clean UI** - Carbonfox theme with mini.statusline and automatic trailing whitespace trimming

## 🚀 Quick Start

### Prerequisites

- Neovim ≥ 0.9
- Git
- A C compiler (for Telescope fzf-native: `gcc`, `clang`, or `make`)
- Node.js (for Copilot and some LSP servers)
- [Optional] `ripgrep` for faster live grep in Telescope
- [Optional] Perforce CLI (`p4`) if using Perforce features
- [Optional] A Nerd Font for icons (set `vim.g.have_nerd_font = true` in [init.lua](init.lua))

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

1. **Wait for plugins to install**: On first launch, lazy.nvim will automatically download and install all plugins
2. **Install LSP servers**: Run `:Mason` and press `i` on desired servers (e.g., `clangd`, `lua_ls`, `pyright`, `rust_analyzer`)
3. **Configure newly installed servers**: Run `:LspSetupInstalled` or restart Neovim after installing servers
4. **Set up Copilot**: Run `:Copilot setup` and follow the GitHub authentication flow
5. **Start coding!**

## ⌨️ Keybindings

### General

| Mode | Key | Action |
|------|-----|--------|
| - | `Space` | Leader key |
| `n` | `\` | Reveal current file in Neo-tree |
| `n` | `Ctrl+\` | Close Neo-tree |
| `n` | `Ctrl+p` | Find files (Telescope) |
| `n` | `Ctrl+b` | Find buffers (Telescope) |
| `n` | `Ctrl+g` | Grep search / live grep (Telescope) |
| `n` | `Alt+v` | Start V-block selection (WSL-friendly `Ctrl+v`) |
| `n` | `Esc` | Clear search highlights |

### Cursor & Editing (VS Code-like)

| Mode | Key | Action |
|------|-----|--------|
| `n` `i` `v` | `Alt+j` / `Alt+↓` | Move line/block down |
| `n` `i` `v` | `Alt+k` / `Alt+↑` | Move line/block up |
| `n` `v` `i` | `Alt+→` | Jump word forward |
| `n` `v` `i` | `Alt+←` | Jump word backward |
| `n` `i` | `Alt+Backspace` | Delete word backward |
| `n` `i` | `Alt+Delete` | Delete word forward |
| `n` | `gg` | Go to top of file |
| `n` | `G` | Go to bottom of file |

### LSP (Code Intelligence)

#### Main LSP Namespace (`<leader>l`)

| Mode | Key | Action |
|------|-----|--------|
| `n` | `<leader>ld` | Goto Definition |
| `n` | `<leader>lD` | Goto Declaration |
| `n` | `<leader>lr` | References |
| `n` | `<leader>li` | Goto Implementation |
| `n` | `<leader>lh` | Hover |
| `n` | `<leader>ls` | Signature Help |
| `n` | `<leader>lR` | Rename |
| `n` | `<leader>la` | Code Action |
| `n` | `<leader>lF` | Format Buffer |
| `n` | `<leader>lS` | Workspace Symbols |
| `n` | `<leader>lx` | Line Diagnostics |
| `n` | `<leader>lX` | Restart LSP Clients |
| `n` | `<leader>lH` | Toggle Inlay Hints |
| `n` | `[d` | Previous Diagnostic |
| `n` | `]d` | Next Diagnostic |

#### Workspace Folders

| Mode | Key | Action |
|------|-----|--------|
| `n` | `<leader>lwA` | Add Workspace Folder |
| `n` | `<leader>lwR` | Remove Workspace Folder |
| `n` | `<leader>lwl` | List Workspace Folders |
 (nvim-cmp)

| Mode | Key | Action |
|------|-----|--------|
| `i` | `Ctrl+Space` | Trigger completion menu (manual) |
| `i` | `Enter` | Confirm selection |
| `i` | `j` / `k` | Next / previous item |

**Note:** Completion is manual by design (does not auto-open). Press `Ctrl+Space` to trigger. `Tab` is reserved for Copilot suggestions.

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
| `n` | `<leader>pD` | Delete current file |
| `n` | `<leader>pR` | Move/rename current file |
| `n` | `<leader>pd` | Diff current file |

#### Perforce Changelist Manager (`:P4Window` or `<leader>ps`)

| Mode | Key | Action |
|------|-----|--------|
| `n` | `Enter` | Open file / Edit CL description / Toggle shelf |
| `n` | `d` | Show diff |
| `n` | `r` | Revert file or CL |
| `n` | `m` | Move file to different CL |
| `n` | `s` | Shelve file or CL |
| `n` | `u` | Unshelve file or CL |
| `n` | `D` | Delete file, CL, or shelf |


### Command Runner (`:Run`)

| Mode | Key | Action |
|------|-----|--------|
| - | `:Run <command>` | Run command async with live output |
| - | `:Run` (no args) | Prompt for command with intelligent completion |
| `n` | `<leader>r` | Prompt for command (pre-fills `:Run `) |
| `n` (output) | `Enter` / `gf` | Open file at line under cursor |
| `n` (output) | `Tab` / `Shift+Tab` | Jump to next / previous error location |
| `n` (output) | `r` | Re-run last command |
| `n` (output) | `k` | Kill running job |

**Examples:**
```vim
:Run make
:Run cargo build
:Run g++ -Wall main.cpp -o main
:Run npm test
:Run python script.py
```

**Features:**
- **Smart completion**: Path completion, command completion from `$PATH`, and environment variable completion
- **Error parsing**: Recognizes compiler/linter output (GCC, Clang, Rust, Python, etc.)
- **Persistent output**: Buffer persists when closing the window with `:q`
- **Background execution**: Terminal remains usable while command runs
- **Clickable errors**: Jump directly to error location with `Enter` or `gf`

### Neo-tree (File Explorer)

| Mode | Key | Action |
|------|-----|--------|
| `n` | `\` | Reveal current file in Neo-tree |
| `n` | `Ctrl+\` | Close Neo-tree |
| `n` | `Enter` / `l` | Open file/expand directory |
| `n` | `h` / `Backspace` | Close directory / navigate to parent |
| `n` | `a` | Add file/directory (end with `/` for directory) |
| `n` | `d` | Delete file/directory |
| `n` | `r` | Rename file/directory |
| `n` | `y` | Copy to clipboard |
| `n` | `x` | Cut to clipboard |
| `n` | `p` | Paste from clipboard |
| `n` | `H` | Toggle hidden files visibility |
| `n` | `R` | Refresh tree |
| `n` | `?` | Show help / keybinding reference |

## 📂 Project Structure

```
├── init.lua                  # Entry point: bootstraps lazy.nvim and loads modules
├── lazy-lock.json            # Plugin version lockfile (auto-generated)
├── lua/
│   ├── config/
│   │   ├── options.lua       # Vim options (line numbers, clipboard, indentation, etc.)
│   │   ├── keymaps.lua       # Core keymaps (VS Code-like line/word movement)
│   │   └── autocmds.lua      # Autocommands (yank highlight)
│   ├── custom/
│   │   ├── perforce.lua      # Perforce integration (changelist manager, P4 commands)
│   │   └── run.lua           # Async command runner (:Run with smart completion)
│   └── plugins/
│       ├── colors.lua        # Theme configuration (Carbonfox from nightfox.nvim)
│       ├── completion.lua    # nvim-cmp setup (manual completion with Ctrl+Space)
│       ├── copilot.lua       # GitHub Copilot configuration
│       ├── fugitive.lua      # Git integration (vim-fugitive)
│       ├── guess-indent.lua  # Auto-detect indentation per file
│       ├── lsp.lua           # LSP setup with Mason (auto-configures installed servers)
│       ├── neo-tree.lua      # File explorer with file watcher
│       ├── telescope.lua     # Fuzzy finder (files, buffers, live grep)
│       ├── treesitter.lua    # Treesitter for better syntax highlighting
│       └── ui.lua            # Statusline (mini.statusline) & auto-trim whitespace
```

## 🔌 Plugins

Core plugin manager:
- **[lazy.nvim](https://github.com/folke/lazy.nvim)** - Modern, fast plugin manager with lazy loading

Development tools:
- **[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)** - LSP client configurations
- **[mason.nvim](https://github.com/mason-org/mason.nvim)** - LSP/DAP/linter installer
- **[mason-lspconfig.nvim](https://github.com/mason-org/mason-lspconfig.nvim)** - Bridge between Mason and lspconfig
- **[nvim-cmp](https://github.com/hrsh7th/nvim-cmp)** + **cmp-nvim-lsp** + **LuaSnip** - Completion framework
- **[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)** - Advanced syntax highlighting
- **[copilot.vim](https://github.com/github/copilot.vim)** - GitHub Copilot AI assistance

Navigation:
- **[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)** + **telescope-fzf-native** - Fuzzy finder (files, buffers, grep)
- **[neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)** + **nui.nvim** + **nvim-web-devicons** - File explorer with icons

Version control:
- **[vim-fugitive](https://github.com/tpope/vim-fugitive)** - Git integration

UI and utilities:
- **[nightfox.nvim](https://github.com/EdenEast/nightfox.nvim)** - Color scheme collection (using Carbonfox)
- **[mini.nvim](https://github.com/echasnovski/mini.nvim)** - Statusline and trailing whitespace management
- **[guess-indent.nvim](https://github.com/NMAC427/guess-indent.nvim)** - Auto-detect indentation style

## 🛠️ Configuration

### LSP Servers

**No manual configuration needed!** The LSP setup auto-configures all servers installed through Mason:

1. Run `:Mason` to open the Mason UI
2. Navigate to the server you want (e.g., `gopls`, `rust_analyzer`, `clangd`, `pyright`)
3. Press `i` to install it
4. Run `:LspSetupInstalled` or restart Neovim to activate it

To customize server-specific settings, edit the `server_overrides` table in [lua/plugins/lsp.lua](lua/plugins/lsp.lua):

```lua
local server_overrides = {
  lua_ls = { settings = { Lua = { completion = { callSnippet = 'Replace' } } } },
  clangd = { cmd = { 'clangd', '--background-index', '--clang-tidy' } },
  rust_analyzer = { settings = { ['rust-analyzer'] = { checkOnSave = { command = 'clippy' } } } },
}
```

### Change Theme

Edit `lua/plugins/colors.lua` and change `carbonfox` to another nightfox variant:
- `nightfox`, `dayfox`, `dawnfox`, `duskfox`, `nordfox`, `terafox`, `carbonfox`

### Add More LSP Servers

**No code editing needed!** Simply:

1. Run `:Mason`
2. Navigate to the server you want (e.g., `gopls`, `rust_analyzer`, `clangd`)
3. Press `i` to install
4. Run `:LspSetupInstalled` or restart Neovim

## 🐛 Troubleshooting

**LSP server not working after installing a server?**
- Servers must be installed via `:Mason` UI (not by editing config)
- After installing, run `:LspSetupInstalled` or restart Neovim
- Verify server is attached: `:LspInfo` (should show "client(s) attached")
- Check server logs: `:LspLog`

**Copilot not suggesting?**
- Check status: `:Copilot status`
- Authenticate: `:Copilot setup`
- If still not working, try `:Copilot restart`

**Telescope not finding files or grep not working?**
- Ensure you're in a project directory (not just an isolated file)
- Install `ripgrep` for live grep: `brew install ripgrep` (macOS) or `sudo apt install ripgrep` (Linux)
- Check `find_files` is using correct directory: should default to `cwd`

**Completion menu not appearing?**
- Completion is manual: press `Ctrl+Space` to trigger
- Ensure LSP is running: `:LspInfo`
- Check if LSP provides completion capabilities: look for "textDocument/completion" in `:LspInfo`

**Perforce commands failing?**
- Verify `p4` is available: `which p4` or `p4 -V`
- Test connection: `p4 info`
- Check login status: `p4 login -s` (login if needed: `p4 login`)
- Ensure `P4CLIENT`, `P4PORT`, and `P4USER` environment variables are set correctly

**Neo-tree or Telescope icons not showing?**
- Make sure you have a Nerd Font installed and selected in your terminal
- Set `vim.g.have_nerd_font = true` in [init.lua](init.lua) (should be default)

## 💭 Philosophy & Design Decisions

**Keybindings:**
- Leader key is `Space`
- VS Code-inspired line movement (`Alt+j/k`) and word navigation (`Alt+←/→`)
- `Tab` is reserved for Copilot (not completion cycling)

**Editor behavior:**
- Line numbers (relative + absolute) and cursorline enabled by default
- Clipboard automatically syncs with system clipboard
- Persistent undo history across sessions (stored in `~/.local/state/nvim/undo/`)
- Case-insensitive search unless pattern contains capitals
- Splits open to right/bottom (more intuitive)

**Formatting:**
- Trailing whitespace and EOF blank lines auto-trimmed on save
- Default indentation: 4 spaces (detects per-file with guess-indent.nvim)
- Tab/space preference auto-detected

**LSP philosophy:**
- Install servers via `:Mason` UI, not config editing
- All Mason-installed servers auto-configure on startup
- Keybindings namespaced under `<leader>l...` for clarity

**Completion:**
- Manual trigger by design (`Ctrl+Space`) - reduces noise
- LSP sources take priority over other sources

**Version control:**
- Git and Perforce can coexist peacefully
- Use vim-fugitive for Git (`:Git`, `<leader>gs`, `<leader>gd`)
- Use custom P4 commands for Perforce (`<leader>p...`)

**Performance:**
- Plugins lazy-load where appropriate (Telescope, Neo-tree)
- Treesitter provides fast, incremental syntax parsing
- File watcher enabled in Neo-tree for live updates

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
