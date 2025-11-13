-- Minimal UI utilities: statusline and trim-on-save via mini.nvim
return {
  'echasnovski/mini.nvim',
  config = function()
    -- Statusline
    local statusline = require 'mini.statusline'
    statusline.setup { use_icons = vim.g.have_nerd_font }
    statusline.section_location = function()
      return '%2l:%-2v'
    end

    -- Trim trailing whitespace / extra blank lines at EOF
    require('mini.trailspace').setup()
    local grp = vim.api.nvim_create_augroup('mini-trim-on-save', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePre', {
      group = grp,
      callback = function()
        local ok, ts = pcall(require, 'mini.trailspace')
        if ok then
          ts.trim()
          if ts.trim_last_lines then ts.trim_last_lines() end
        end
      end,
    })
  end,
}
