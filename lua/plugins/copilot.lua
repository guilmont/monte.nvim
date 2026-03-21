return {
  'github/copilot.vim',
  config = function()
    -- Disable default Tab mapping so Tab remains indentation/navigation.
    vim.g.copilot_no_tab_map = true

    -- Accept suggestion with Alt+Enter.
    vim.keymap.set('i', '<M-CR>', function()
      return vim.fn['copilot#Accept']('')
    end,
      { expr = true, replace_keycodes = false, silent = true, desc = 'Accept Copilot (Alt+Enter)' })

    -- Navigate between suggestions
    vim.keymap.set('i', '<M-]>', '<Plug>(copilot-next)', { silent = true, desc = 'Next Copilot suggestion' })
    vim.keymap.set('i', '<M-[>', '<Plug>(copilot-previous)', { silent = true, desc = 'Previous Copilot suggestion' })

    -- Dismiss suggestion
    vim.keymap.set('i', '<M-d>', '<Plug>(copilot-dismiss)', { silent = true, desc = 'Dismiss Copilot' })

    -- Manually trigger suggestion (if auto-suggest is off or slow)
    vim.keymap.set('i', '<M-\\>', '<Plug>(copilot-suggest)', { silent = true, desc = 'Trigger Copilot' })
  end,
}
