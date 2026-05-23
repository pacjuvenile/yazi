local M = {}

function M.quote(s)
	return tostring(s or ""):gsub("'", "''")
end

function M.join(lines)
	return table.concat(lines, "\n")
end

function M.bool(value)
	return value and "$true" or "$false"
end

return M
