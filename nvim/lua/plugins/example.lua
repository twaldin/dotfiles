return {
    -- Add catppuccin colorscheme
    {
        "folke/tokyonight.nvim",
        name = "tokyonight",
        priority = 1000,
        lazy = true,
        opts = {
            style = "moon",
        },
    },
    -- Configure LazyVim
    {
        "LazyVim/LazyVim",
        opts = {
            colorscheme = "tokyonight",
        },
    },
}
