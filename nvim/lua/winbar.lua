local M = {}

function M.status()
	local current_file = vim.fn.expand('%:.')
	if current_file == "" then return "" end

	local handle = io.popen("git diff --numstat " .. vim.fn.shellescape(current_file) .. " 2>/dev/null")
	if handle then
		local result = handle:read("*a")
		handle:close()
		if result and result ~= "" then
			local added, removed = result:match("(%d+)%s+(%d+)")
			if added and removed then
				local status = ""
				if tonumber(added) > 0 then status = status .. " %#GruvboxGreen#+" .. added .. "%*" end
				if tonumber(removed) > 0 then status = status .. " %#GruvboxRed#-" .. removed .. "%*" end
				return status
			end
		end
	end

	-- Check if file is untracked
	local handle2 = io.popen("git status --porcelain " .. vim.fn.shellescape(current_file) .. " 2>/dev/null")
	if handle2 then
		local result2 = handle2:read("*a")
		handle2:close()
		if result2 and result2:match("^%?%?") then
			return " %#GruvboxGreen#new%*"
		end
	end

	return ""
end

function M.get_search_count()
	local ok, result = pcall(vim.fn.searchcount, {maxcount = 999})
	if ok and result and result.total and result.total > 0 then
		return string.format("%d/%d ", result.current, result.total)
	end
	return ""
end

function M.get_winbar()
	local full_path = vim.fn.expand('%:.')
	if full_path == "" then return "" end

	local parts = {}
	for part in full_path:gmatch("[^/]+") do
		table.insert(parts, part)
	end

	if #parts == 0 then return "" end

	local path_display = ""
	if #parts > 1 then
		-- Show all but last part in normal color
		for i = 1, #parts - 1 do
			if i > 1 then path_display = path_display .. "/" end
			path_display = path_display .. parts[i]
		end
		path_display = path_display .. "/"
	end

	-- Show last part (filename) in orange
	path_display = path_display .. "%#GruvboxOrange#" .. parts[#parts] .. "%*"

	-- Add git status and right-align search count, mode/position info
	return path_display .. M.status() .. "%=" .. "%{v:lua.get_search_count()}" .. "  [%{mode()}] (%l,%c) "
end

return M
