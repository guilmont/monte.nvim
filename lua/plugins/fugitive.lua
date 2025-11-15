return {
  "tpope/vim-fugitive",
  cmd = { "Git", "Gvdiffsplit" },
  keys = {
    { "<leader>gs", ":Git<CR>", { desc = "Git Status", silent = true } },
    { "<leader>gd", ":Gvdiffsplit<CR>", { desc = "Git Vertical Diff", silent = true } },
  },
}
