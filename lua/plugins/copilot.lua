return {
  'github/copilot.vim',
  config = function()
    -- Disable default Tab mapping so we can customize it
    vim.g.copilot_no_tab_map = true
    
    -- Accept suggestion with Tab (like VS Code)
    vim.keymap.set('i', '<Tab>', function()
      local suggestion = vim.fn['copilot#Accept']('')
      if suggestion ~= '' then
        return suggestion
      else
        -- Fallback to regular Tab if no suggestion
        return '<Tab>'
      end
    end, { expr = true, replace_keycodes = false, silent = true })
    
    -- Navigate between suggestions
    vim.keymap.set('i', '<M-]>', '<Plug>(copilot-next)', { silent = true, desc = 'Next Copilot suggestion' })
    vim.keymap.set('i', '<M-[>', '<Plug>(copilot-previous)', { silent = true, desc = 'Previous Copilot suggestion' })
    
    -- Dismiss suggestion
    vim.keymap.set('i', '<C-e>', '<Plug>(copilot-dismiss)', { silent = true, desc = 'Dismiss Copilot' })
    
    -- Manually trigger suggestion (if auto-suggest is off or slow)
    vim.keymap.set('i', '<M-\\>', '<Plug>(copilot-suggest)', { silent = true, desc = 'Trigger Copilot' })
  end,
}
