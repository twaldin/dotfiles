local M = {}

function M.open_floating_cmdline()
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
	
	vim.cmd('startinsert')
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {':'})
	vim.api.nvim_win_set_cursor(win, {1, 1})

	vim.api.nvim_buf_set_keymap(buf, 'i', '<CR>', '<Esc>:lua require("cmdline").execute_command()<CR>', {noremap = true, silent = true})
	vim.api.nvim_buf_set_keymap(buf, 'i', '<Esc>', '<Esc>:lua require("cmdline").close_window()<CR>', {noremap = true, silent = true})
	
	M.current_win = win
	M.current_buf = buf
end

function M.execute_command()
	if not M.current_buf then return end
	
	local lines = vim.api.nvim_buf_get_lines(M.current_buf, 0, -1, false)
	local command = lines[1] or ""
	
	M.close_window()
	
	if command:sub(1,1) == ':' then
		command = command:sub(2)
	end
	
	if command ~= "" then
		vim.cmd(command)
	end
end

function M.close_window()
	if M.current_win and vim.api.nvim_win_is_valid(M.current_win) then
		vim.api.nvim_win_close(M.current_win, true)
	end
	M.current_win = nil
	M.current_buf = nil
end

return M