local M = {}

M.defaults = {
	-- "tab" opens the dashboard in its own tabpage; "split" puts it beside the
	-- buffer you are in.
	layout = "tab",
	-- "auto" ajusta el ancho a las columnas renderizadas; también acepta un número.
	watchlist_width = "auto",

	auto_refresh = 15, -- seconds; 0 disables
	log_tail = 200,
	log_max_lines = 10000,
	log_follow = true,

	confirm_actions = true,

	-- Only used by the `T` escape hatch (logs in a tmux pane).
	tmux_split_cmd = "tmux split-window -h '%s; read'",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(user_opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

function M.get()
	return M.options
end

return M
