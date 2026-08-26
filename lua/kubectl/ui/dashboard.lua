-- The single screen. Owns the watchlist window, its render loop and every
-- contextual keymap. The focused line is the implicit subject of each action.
local M = {}

local conf = require("kubectl.config")
local state = require("kubectl.state")
local wl = require("kubectl.watchlist")
local client = require("kubectl.k8s_client")
local fmt = require("kubectl.format")

local HL_NS = vim.api.nvim_create_namespace("kubectl_dashboard")
local EMPTY = "  (watchlist empty — press 'a' to add a deployment)"

M.buf = nil
M.win = nil
M.rows = {} -- buffer line number -> row table

local function notify(msg, level)
	vim.notify("kubectl: " .. msg, level or vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

local function set_winbar()
	if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
		return
	end
	local c = conf.get()
	local refresh = c.auto_refresh > 0 and string.format("%ds", c.auto_refresh) or "manual"
	vim.wo[M.win].winbar = table.concat({
		"%#Title#ctx:%* " .. (state.context or "?"),
		"%#Title#ns:%* " .. (state.namespace or "?"),
		"%#Comment#" .. refresh .. "  ?=help%*",
	}, "  │  ")
end

--- Remember which deployment the cursor was on, so a refresh does not move it.
local function cursor_key()
	if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
		return nil
	end
	local row = M.rows[vim.api.nvim_win_get_cursor(M.win)[1]]
	return row and (row.ns .. "/" .. row.name) or nil
end

--- Put the cursor back on the deployment it was on. With no match — the first
-- render, or the row disappeared — fall back to the first row: line 1 is the
-- header, and a cursor parked there makes every contextual action a no-op.
local function place_cursor(key)
	if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
		return
	end
	local target
	if key then
		for lnum, row in pairs(M.rows) do
			if row.ns .. "/" .. row.name == key then
				target = lnum
				break
			end
		end
	end
	if not target and next(M.rows) then
		target = 2 -- first row; M.rows is keyed by buffer line and starts at 2
	end
	if target then
		pcall(vim.api.nvim_win_set_cursor, M.win, { target, 0 })
	end
end

--- Paint the buffer from per-namespace snapshots.
-- @param snaps table: namespace -> { deployments = {...}, pods = {...} }
function M.render(snaps)
	if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
		return
	end
	local key = cursor_key()
	M.rows = {}

	-- Resolve every watchlist entry against its namespace snapshot first, so the
	-- column widths can be sized to the data actually on screen.
	local rows = {}
	for _, entry in ipairs(wl.list(state.context)) do
		local snap = snaps[entry.namespace]
		local deploy
		for _, d in ipairs(snap and snap.deployments or {}) do
			if d.metadata.name == entry.name then
				deploy = d
				break
			end
		end
		table.insert(rows, deploy and fmt.build_row(deploy, snap.pods) or fmt.missing_row(entry))
	end

	local widths = fmt.widths(rows)
	local lines, highlights = { fmt.header(widths) }, {}
	for _, row in ipairs(rows) do
		table.insert(lines, fmt.render_row(row, widths))
		M.rows[#lines] = row
		if row.severity ~= "ok" then
			highlights[#lines] = row.severity == "error" and "DiagnosticError" or "DiagnosticWarn"
		end
	end

	M.content_width = #lines[1]
	if #lines == 1 then
		table.insert(lines, EMPTY)
	end

	vim.bo[M.buf].modifiable = true
	vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
	vim.bo[M.buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(M.buf, HL_NS, 0, -1)
	vim.api.nvim_buf_set_extmark(M.buf, HL_NS, 0, 0, { end_col = #lines[1], hl_group = "Title" })
	for lnum, group in pairs(highlights) do
		vim.api.nvim_buf_set_extmark(M.buf, HL_NS, lnum - 1, 0, { end_row = lnum, hl_group = group })
	end

	set_winbar()
	M.apply_width()
	place_cursor(key)
end

--- Fetch every namespace in the watchlist in parallel, then render once.
function M.refresh()
	if not state.context then
		return
	end
	local namespaces = wl.namespaces(state.context)
	if #namespaces == 0 then
		return M.render({})
	end

	local snaps, pending = {}, #namespaces
	for _, ns in ipairs(namespaces) do
		client.snapshot(ns, function(snap, err)
			snaps[ns] = snap or { deployments = {}, pods = {} }
			if err then
				notify(ns .. ": " .. err, vim.log.levels.WARN)
			end
			pending = pending - 1
			if pending == 0 then
				M.render(snaps)
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Contextual actions
-- ---------------------------------------------------------------------------

--- The row under the cursor, or nil (with a nudge) if there is none.
function M.current_row()
	if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
		return nil
	end
	local row = M.rows[vim.api.nvim_win_get_cursor(M.win)[1]]
	if not row then
		notify("no deployment on this line", vim.log.levels.WARN)
	end
	return row
end

local function add_deployment()
	local ns = state.namespace
	client.get_deployments(ns, function(items, err)
		if not items then
			return notify(err, vim.log.levels.ERROR)
		end
		local names = {}
		for _, d in ipairs(items) do
			table.insert(names, d.metadata.name)
		end
		if #names == 0 then
			return notify("no deployments in " .. ns)
		end
		vim.ui.select(names, { prompt = "Add to the watchlist (" .. ns .. "):" }, function(choice)
			if not choice then
				return
			end
			if wl.add(state.context, ns, choice) then
				notify(choice .. " added")
			else
				notify(choice .. " was already on the watchlist")
			end
			M.refresh()
		end)
	end)
end

local function pick_namespace()
	client.get_namespaces(function(names, err)
		if not names then
			return notify(err, vim.log.levels.ERROR)
		end
		vim.ui.select(names, { prompt = "Default namespace:" }, function(choice)
			if choice then
				state.namespace = choice
				set_winbar()
				notify("default namespace: " .. choice)
			end
		end)
	end)
end

local function show_help()
	local lines = {
		" kubectl.nvim ",
		"",
		" <CR>  logs in the active pane      a  add a deployment",
		" o     logs in a new pane           d  remove from watchlist",
		" R     rollout restart              i  change the whole image",
		" s     scale to N                   v  change only the version",
		" 0     scale to 0                   n  default namespace",
		" e     deployment events            K  describe / detail",
		" T     logs in a tmux pane          r  refresh now",
		" q     close                        ?  this help",
		"",
		" In a log pane:  / search   g grep   t tail   f follow   x close",
		" <leader>F  zoom the log pane full width (again to restore)",
		"",
	}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, #l)
	end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width + 2,
		height = #lines,
		row = math.floor((vim.o.lines - #lines) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Keymaps ",
	})
	vim.bo[buf].bufhidden = "wipe"
	for _, k in ipairs({ "q", "<Esc>", "?" }) do
		vim.keymap.set("n", k, function()
			pcall(vim.api.nvim_win_close, win, true)
		end, { buffer = buf, nowait = true, silent = true })
	end
end

--- Open a read-only scratch pane with arbitrary kubectl text output.
function M.show_text(title, text)
	local logs = require("kubectl.ui.logs")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "kubectl-detail"
	vim.api.nvim_buf_set_name(buf, "kubectl://" .. title)
	logs.place(buf, false)
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
end

--- Actions that do not depend on the focused row. The log panes map these too,
-- so the dashboard stays reachable without hopping back to the watchlist first.
M.global_keymaps = {
	{ "a", add_deployment, "Add a deployment" },
	{ "n", pick_namespace, "Default namespace" },
	{ "r", function()
		M.refresh()
	end, "Refresh" },
	{ "?", show_help, "Help" },
}

local function set_keymaps(buf)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	local function on_row(fn)
		return function()
			local row = M.current_row()
			if row then
				fn(row)
			end
		end
	end
	local actions = function()
		return require("kubectl.actions")
	end
	local logs = function()
		return require("kubectl.ui.logs")
	end

	map("<CR>", on_row(function(row)
		logs().open(row, false)
	end), "Logs in the active pane")
	map("o", on_row(function(row)
		logs().open(row, true)
	end), "Logs in a new pane")
	map("T", on_row(function(row)
		logs().open_tmux(row)
	end), "Logs in tmux")

	map("d", on_row(function(row)
		actions().remove(row)
	end), "Remove from the watchlist")
	map("R", on_row(function(row)
		actions().restart(row)
	end), "Rollout restart")
	map("i", on_row(function(row)
		actions().set_image(row)
	end), "Change the image")
	map("v", on_row(function(row)
		actions().set_version(row)
	end), "Change the version")
	map("s", on_row(function(row)
		actions().scale(row)
	end), "Scale")
	map("0", on_row(function(row)
		actions().scale(row, 0)
	end), "Scale to 0")
	map("e", on_row(function(row)
		actions().events(row)
	end), "Events")
	map("K", on_row(function(row)
		actions().describe(row)
	end), "Describe")

	map("<Tab>", function()
		if not logs().focus() then
			notify("no log pane is open")
		end
	end, "Go to the log pane")

	for _, m in ipairs(M.global_keymaps) do
		map(m[1], m[2], m[3])
	end
	map("<leader>F", function()
		logs().toggle_zoom()
	end, "Zoom the log pane")
	map("q", M.close, "Close")
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function create_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "kubectl-dashboard"
	vim.api.nvim_buf_set_name(buf, "kubectl://watchlist")
	set_keymaps(buf)

	-- Closing the window wipes the buffer; that is our single cleanup hook.
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			state.cleanup()
			M.buf, M.win, M.rows = nil, nil, {}
		end,
	})
	return buf
end

local function start_timer()
	state.stop_timer()
	local interval = conf.get().auto_refresh
	if interval <= 0 then
		return
	end
	state.timer = vim.uv.new_timer()
	state.timer:start(
		interval * 1000,
		interval * 1000,
		vim.schedule_wrap(function()
			if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
				M.refresh()
			else
				state.stop_timer()
			end
		end)
	)
end

function M.is_open()
	return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Size the watchlist window. "auto" fits the rendered columns; either way it
-- is capped at 60% of the tab so the log pane stays usable on a narrow terminal.
function M.apply_width()
	if not M.is_open() then
		return
	end
	-- A refresh must not undo a <leader>F zoom: the timer fires every few
	-- seconds and would snap the log pane back mid-read.
	if require("kubectl.ui.logs").is_zoomed() then
		return
	end
	local want = conf.get().watchlist_width
	if type(want) ~= "number" then
		want = (M.content_width or 60) + 2
	end
	vim.api.nvim_win_set_width(M.win, math.min(want, math.floor(vim.o.columns * 0.6)))
end

function M.open()
	if M.is_open() then
		vim.api.nvim_set_current_win(M.win)
		return
	end

	local c = conf.get()
	if c.layout == "tab" then
		vim.cmd("tabnew")
	else
		vim.cmd("topleft vnew")
	end
	local scratch = vim.api.nvim_get_current_buf()

	M.win = vim.api.nvim_get_current_win()
	M.buf = create_buf()
	vim.api.nvim_win_set_buf(M.win, M.buf)
	pcall(vim.api.nvim_buf_delete, scratch, { force = true })

	M.apply_width()
	vim.wo[M.win].winfixwidth = true
	vim.wo[M.win].wrap = false
	vim.wo[M.win].number = false
	vim.wo[M.win].relativenumber = false
	vim.wo[M.win].signcolumn = "no"
	vim.wo[M.win].cursorline = true

	M.render({})
	start_timer()

	-- Context first: every watchlist lookup and kubectl call is scoped by it.
	client.context_info(function(info, err)
		if not info then
			return notify(err or "sin contexto", vim.log.levels.ERROR)
		end
		state.context = info.context
		state.namespace = state.namespace or info.namespace
		M.refresh()
	end)
end

function M.close()
	require("kubectl.ui.logs").close_all()
	state.cleanup()
	if M.is_open() then
		local c = conf.get()
		if c.layout == "tab" and vim.fn.tabpagenr("$") > 1 then
			vim.cmd("tabclose")
		else
			pcall(vim.api.nvim_win_close, M.win, true)
		end
	end
	M.buf, M.win, M.rows = nil, nil, {}
end

function M.toggle()
	if M.is_open() then
		M.close()
	else
		M.open()
	end
end

--- Give the watchlist window focus (used after acting from a log pane).
function M.focus()
	if M.is_open() then
		vim.api.nvim_set_current_win(M.win)
	end
end

return M
