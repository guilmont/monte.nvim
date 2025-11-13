-- Detect indentation from file content
return {
  'NMAC427/guess-indent.nvim',
  event = 'BufReadPost',
  config = function()
    require('guess-indent').setup {}
  end,
}
