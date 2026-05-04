-- Detect indentation from file content
return {
  'NMAC427/guess-indent.nvim',
  event = 'BufReadPost',
  config = function()
    require('guess-indent').setup {
      override_editorconfig = true,
      filetype_exclude = {},
      buftype_exclude = { 'help', 'nofile', 'terminal', 'prompt' },
      on_tab_options = {
        expandtab = true,   -- keep spaces even when file uses tabs
      },
      on_space_options = {},
    }
  end,
}
