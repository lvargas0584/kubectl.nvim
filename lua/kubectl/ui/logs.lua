-- Log panes. Several streams can be visible at once: the area to the right of
-- the watchlist is split into normal windows, so Neovim does the layout work
-- and `/` `n` `N` search each pane for free.
local M = {}

local conf = require("kubectl.config")
local state = require("kubectl.state")
local client = require("kubectl.k8s_client")

M.panes = {} -- buffer number -> pane

local function notify(msg, level)
	vim.notify("kubectl: " .. msg, level or vim.log.levels.INFO)
end

--- Windows in this tabpage that belong to the log area.
local function pane_wins()
	local out = {}
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local b = vim.api.nvim_win_get_buf(w)
		if vim.b[b].kubectl_pane then
			table.insert(out, w)
		end
	end
	return out
end

local function set_pane_winbar(win, pane)
	if not pane then
		return
	end
	local parts = {
		"%#Title#" .. pane.deploy .. "%*",
		pane.pod,
		"tail " .. pane.tail,
	}
	if pane.grep and pane.grep ~= "" then
		table.insert(parts, "%#DiagnosticWarn#grep: " .. pane.grep .. "%*")
	end
	table.insert(parts, pane.follow and "follow" or "%#Comment#paused%*")
	vim.wo[win].winbar = table.concat(parts, "  │  ")
end

--- Keymaps every pane gets, whether it holds a log stream or `describe` output:
-- the row-independent dashboard actions plus pane navigation.
local function shared_keymaps(buf)
	local dash = require("kubectl.ui.dashboard")
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	for _, m in ipairs(dash.global_keymaps) do
		map(m[1], m[2], m[3])
	end
	map("<Tab>", function()
		dash.focus()
	end, "Back to the watchlist")
	map("x", "<cmd>close<cr>", "Close this pane")
end

--- Put a buffer into the log area. `new_pane` stacks a new window instead of
-- reusing the first one.
-- @return number|nil: the window it landed in
function M.place(buf, new_pane)
	vim.b[buf].kubectl_pane = true
	shared_keymaps(buf)
	local wins = pane_wins()
	local dash = require("kubectl.ui.dashboard")
	local origin = vim.api.nvim_get_current_win()

	if #wins == 0 then
		if not dash.is_open() then
			return nil
		end
		vim.api.nvim_set_current_win(dash.win)
		vim.cmd("rightbelow vsplit")
		dash.apply_width() -- el split reparte al 50%; la watchlist recupera su ancho
	elseif new_pane then
		vim.api.nvim_set_current_win(wins[#wins])
		vim.cmd("rightbelow split")
	else
		vim.api.nvim_set_current_win(wins[1])
	end

	local win = vim.api.nvim_get_current_win()
	-- Swapping the buffer wipes the previous pane, whose BufWipeout hook kills
	-- its stream. No manual bookkeeping needed.
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].wrap = false
	vim.wo[win].signcolumn = "no"
	set_pane_winbar(win, M.panes[buf])

	if vim.api.nvim_win_is_valid(origin) then
		vim.api.nvim_set_current_win(origin)
	end
	return win
end

local function window_for(buf)
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(w) == buf then
			return w
		end
	end
	return nil
end

local function append(pane, lines)
	local buf = pane.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local max = conf.get().log_max_lines
	vim.bo[buf].modifiable = true
	-- Un buffer vacío tiene una línea en blanco; sobrescribirla en vez de añadir
	-- debajo evita un hueco al principio del panel.
	local first = vim.api.nvim_buf_line_count(buf) == 1
		and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
	vim.api.nvim_buf_set_lines(buf, first and 0 or -1, -1, false, lines)
	local count = vim.api.nvim_buf_line_count(buf)
	if count > max then
		vim.api.nvim_buf_set_lines(buf, 0, count - max, false, {})
	end
	vim.bo[buf].modifiable = false

	if pane.follow then
		local win = window_for(buf)
		if win then
			pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
		end
	end
end

--- kubectl writes in chunks, not lines; hold the trailing partial line back
-- until its newline arrives.
local function reader(pane)
	return function(_, data)
		if not data or data == "" then
			return
		end
		local lines = vim.split(pane.partial .. data, "\n", { plain = true })
		pane.partial = table.remove(lines)
		if #lines > 0 then
			vim.schedule(function()
				append(pane, lines)
			end)
		end
	end
end

function M.stop(pane)
	if pane.job then
		state.stop_job(pane.job)
		pane.job = nil
	end
end

function M.stream(pane)
	M.stop(pane)
	pane.partial = ""
	local argv = client.logs_cmd(pane.ns, pane.pod, pane.container, pane.tail)

	if pane.grep and pane.grep ~= "" then
		-- A pipe needs a shell. --line-buffered keeps the stream live.
		local quoted = {}
		for _, a in ipairs(argv) do
			table.insert(quoted, vim.fn.shellescape(a))
		end
		argv = {
			"sh",
			"-c",
			table.concat(quoted, " ") .. " | grep --line-buffered -- " .. vim.fn.shellescape(pane.grep),
		}
	end

	local read = reader(pane)
	pane.job = vim.system(argv, { text = true, stdout = read, stderr = read }, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(pane.buf) then
				return
			end
			local tail = {}
			if pane.partial ~= "" then
				table.insert(tail, pane.partial) -- última línea sin salto final
				pane.partial = ""
			end
			table.insert(tail, "-- stream ended (t/g restart it, x closes) --")
			append(pane, tail)
		end)
	end)
	state.register_job(pane.job, pane.deploy)

	local win = window_for(pane.buf)
	if win then
		set_pane_winbar(win, pane)
	end
end

--- Wipe the buffer contents and restart the stream with the current settings.
local function restream(pane)
	vim.bo[pane.buf].modifiable = true
	vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, {})
	vim.bo[pane.buf].modifiable = false
	M.stream(pane)
end

local function set_keymaps(pane)
	local opts = { buffer = pane.buf, nowait = true, silent = true }
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", opts, { desc = desc }))
	end

	map("g", function()
		vim.ui.input({ prompt = "grep (empty = no filter): ", default = pane.grep or "" }, function(input)
			if input == nil then
				return
			end
			pane.grep = input
			restream(pane)
		end)
	end, "Filter the stream with grep")

	map("t", function()
		vim.ui.input({ prompt = "History lines (--tail): ", default = tostring(pane.tail) }, function(input)
			local n = tonumber(input)
			if not n then
				return
			end
			pane.tail = math.floor(n)
			restream(pane)
		end)
	end, "Change --tail")

	map("f", function()
		pane.follow = not pane.follow
		local win = window_for(pane.buf)
		if win then
			set_pane_winbar(win, pane)
		end
		notify(pane.follow and "follow on" or "follow paused")
	end, "Toggle follow")

	map("<C-c>", function()
		M.stop(pane)
		notify("stream stopped")
	end, "Stop the stream")

end

local function create_buf(pane)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "log"
	pcall(vim.api.nvim_buf_set_name, buf, string.format("kubectl://logs/%s/%s#%d", pane.ns, pane.deploy, buf))

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			M.stop(pane)
			M.panes[buf] = nil
		end,
	})
	return buf
end

--- Stream the newest pod of a deployment into a log pane.
-- @param row table: dashboard row
-- @param new_pane boolean: stack a new pane instead of reusing the active one
function M.open(row, new_pane)
	local c = conf.get()
	client.newest_pod(row.ns, row.name, function(pod, err)
		if not pod then
			return notify(err, vim.log.levels.ERROR)
		end
		local pane = {
			ns = row.ns,
			deploy = row.name,
			pod = pod,
			container = row.container,
			tail = c.log_tail,
			follow = c.log_follow,
			partial = "",
		}
		pane.buf = create_buf(pane)
		M.panes[pane.buf] = pane
		set_keymaps(pane)
		if not M.place(pane.buf, new_pane) then
			return notify("the dashboard is not open", vim.log.levels.WARN)
		end
		M.stream(pane)
	end)
end

--- Escape hatch: stream in a tmux pane instead, to leave it running outside nvim.
function M.open_tmux(row)
	client.newest_pod(row.ns, row.name, function(pod, err)
		if not pod then
			return notify(err, vim.log.levels.ERROR)
		end
		local argv = client.logs_cmd(row.ns, pod, row.container, conf.get().log_tail)
		local quoted = {}
		for _, a in ipairs(argv) do
			table.insert(quoted, vim.fn.shellescape(a))
		end
		vim.system({ "sh", "-c", string.format(conf.get().tmux_split_cmd, table.concat(quoted, " ")) })
	end)
end

function M.close_all()
	for buf, _ in pairs(M.panes) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	M.panes = {}
end

--- Move focus from the watchlist into the log area.
function M.focus()
	local wins = pane_wins()
	if wins[1] then
		vim.api.nvim_set_current_win(wins[1])
		return true
	end
	return false
end

return M
