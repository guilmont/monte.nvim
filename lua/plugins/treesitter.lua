-- Treesitter: syntax highlighting and indentation
return {
  'nvim-treesitter/nvim-treesitter',
  build = ':TSUpdate',
  -- Provide an explicit config to avoid relying on automatic module loading
  config = function(_, opts)
    local ok, configs = pcall(require, 'nvim-treesitter.configs')
    if ok and configs and type(configs.setup) == 'function' then
      configs.setup(opts)
      return
    end
    -- Plugin not yet installed/loaded; defer setup briefly so lazy.nvim
    -- can install/load the plugin without throwing an error here.
    vim.schedule(function()
      local ok2, configs2 = pcall(require, 'nvim-treesitter.configs')
      if ok2 and configs2 and type(configs2.setup) == 'function' then
        configs2.setup(opts)
      end
    end)
  end,
  opts = {
    ensure_installed = { 'bash', 'c', 'cpp', 'lua', 'rust', 'javascript', 'typescript', 'python', 'vim', 'vimdoc', 'query' },
    auto_install = true,
    highlight = { enable = true },
    indent = { enable = true },
  },
}
