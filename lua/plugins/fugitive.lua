return {
  "tpope/vim-fugitive",
  cmd = { "Git", "Gvdiffsplit" },
  keys = {
    { "<leader>go", ":Git<CR>", desc = "Git Status" },
    { "<leader>gd", ":Gvdiffsplit<CR>", desc = "Git Diff" },
  },
}
