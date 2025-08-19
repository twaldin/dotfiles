local M = {}

function M.open_floating_cmdline(prefix)
	prefix = prefix or ':'
	local width = math.floor(vim.o.columns * 0.6)
	local height = 1
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = vim.api.nvim_create_buf(false, true)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = 'editor',
		width = width,
		height = height,
		row = row,
		col = col,
		style = 'minimal',
		border = 'rounded',
	})

	vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
	vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

	-- disable cmp by default in cmd line
	vim.b[buf].completion = false

	vim.cmd('startinsert')
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {prefix})
	vim.api.nvim_win_set_cursor(win, {1, 1})

	M.prefix = prefix

	vim.api.nvim_buf_set_keymap(buf, 'i', '<CR>', '<Esc>:lua require("cmdline").execute_command()<CR>', {noremap = true, silent = true})
	vim.api.nvim_buf_set_keymap(buf, 'i', '<Esc>', '<Esc>:lua require("cmdline").close_window()<CR>', {noremap = true, silent = true})
	--tab toggles completion
	vim.api.nvim_buf_set_keymap(buf, 'i', '<Tab>', '<Cmd>lua require("cmdline").toggle_completion()<CR>', {noremap = true, silent = true})

	M.current_win = win
	M.current_buf = buf
end

function M.execute_command()
	if not M.current_buf then return end

	local lines = vim.api.nvim_buf_get_lines(M.current_buf, 0, -1, false)
	local command = lines[1] or ""
	local prefix = M.prefix or ':'

	M.close_window()

	-- Remove the prefix character from the beginning
	if command:sub(1,1) == prefix then
		command = command:sub(2)
	end

	if command ~= "" then
		if prefix == ':' then
			vim.cmd(command)
		elseif prefix == '/' then
			vim.fn.setreg('/', command)
			vim.cmd('normal! nzz')
		elseif prefix == '?' then
			vim.fn.setreg('/', command)
			vim.cmd('normal! Nzz')
		end
	end
end

function M.close_window()
	if M.current_win and vim.api.nvim_win_is_valid(M.current_win) then
		vim.api.nvim_win_close(M.current_win, true)
	end
	M.current_win = nil
	M.current_buf = nil
end

function M.toggle_completion()
	if not M.current_buf then return end

	vim.b[M.current_buf].completion = true

	local blink = require('blink.cmp')
	if blink.is_visible() then
		blink.accept()
	else
		blink.show()
	end
end

vim.keymap.set("n", ":", function() M.open_floating_cmdline(':') end)
vim.keymap.set("n", "/", function() M.open_floating_cmdline('/') end)
vim.keymap.set("n", "?", function() M.open_floating_cmdline('?') end)
return M
