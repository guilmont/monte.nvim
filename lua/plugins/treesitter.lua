-- Treesitter: syntax highlighting and indentation
return {
  'nvim-treesitter/nvim-treesitter',
  build = ':TSUpdate',
  main = 'nvim-treesitter.configs',
  opts = {
    ensure_installed = { 'bash', 'c', 'cpp', 'lua', 'rust', 'javascript', 'typescript', 'python', 'vim', 'vimdoc', 'query' },
    auto_install = true,
    highlight = { enable = true },
    indent = { enable = true },
  },
}
