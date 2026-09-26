local M = {}

M.defaults = {
	-- width of the sidebar window
	width = 30,
	-- autocmd events that trigger a refresh of the function list
	update_events = { "BufEnter", "TextChanged", "TextChangedI" },
	-- debounce delay (ms) applied to text-change events (BufEnter is instant)
	debounce_ms = 300,
	-- open the sidebar automatically on startup, for the initial buffer
	auto_open = false,
}

function M.merge(opts)
	return vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
