--remember cursor position
vim.api.nvim_create_autocmd("BufReadPost", {
	callback = function()
		local mark = vim.api.nvim_buf_get_mark(0, '"')
		local lcount = vim.api.nvim_buf_line_count(0)
		if mark[1] > 0 and mark[1] <= lcount then
			pcall(vim.api.nvim_win_set_cursor, 0, mark)
		end
	end,
})

--highlight yanked text briefly
vim.api.nvim_create_autocmd("TextYankPost", {
	callback = function()
		vim.highlight.on_yank({ higroup = "Visual", timeout = 200 })
	end,
})

--remove trailing whitespace on :w
vim.api.nvim_create_autocmd("BufWritePre", {
	callback = function()
		local save_cursor = vim.fn.getpos(".")
		vim.cmd([[%s/\s\+$//e]])
		vim.fn.setpos(".", save_cursor)
	end,
})

--lazy load lsp
vim.api.nvim_create_autocmd("FileType", {
	callback = function(args)
		local ft_to_lsps = {
			c = { "clangd" },
			cpp = { "clangd" },
			dockerfile = { "dockerls" },
			typescript = { "ts_ls" },
			typescriptreact = { "ts_ls" },
			javascript = { "ts_ls" },
			javascriptreact = { "ts_ls" },
			bash = { "bashls" },
			sh = { "bashls" },
			zsh = { "bashls" },
			lua = { "lua_ls" },
		}

		local lsps = ft_to_lsps[args.match]
		if lsps then
			for _, lsp in ipairs(lsps) do
				vim.lsp.enable(lsp)
			end
		end
	end,
})
