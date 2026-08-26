-- The curated set of deployments the user actually works with, persisted
-- across sessions. Entries are { context, namespace, name }.
local M = {}

-- Assignable so tests can point at a scratch file; also lets you relocate the
-- watchlist without touching the module.
M.path = vim.fn.stdpath("data") .. "/kubectl-nvim/watchlist.json"

local entries -- lazily loaded, then kept in memory

--- Drop the in-memory copy, e.g. after M.path changed or the file was edited.
function M.reload()
	entries = nil
end

local function load()
	if entries then
		return entries
	end
	entries = {}
	local f = io.open(M.path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		local ok, data = pcall(vim.json.decode, content)
		if ok and type(data) == "table" then
			for _, e in ipairs(data) do
				if e.context and e.namespace and e.name then
					table.insert(entries, e)
				end
			end
		end
	end
	return entries
end

local function save()
	vim.fn.mkdir(vim.fn.fnamemodify(M.path, ":h"), "p")
	local f, err = io.open(M.path, "w")
	if not f then
		vim.notify("kubectl.nvim: could not save the watchlist: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	f:write(vim.json.encode(entries))
	f:close()
end

local function index_of(context, namespace, name)
	for i, e in ipairs(load()) do
		if e.context == context and e.namespace == namespace and e.name == name then
			return i
		end
	end
	return nil
end

--- Entries for one context, sorted by namespace then name.
function M.list(context)
	local out = {}
	for _, e in ipairs(load()) do
		if e.context == context then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		if a.namespace ~= b.namespace then
			return a.namespace < b.namespace
		end
		return a.name < b.name
	end)
	return out
end

--- @return boolean: false if it was already there
function M.add(context, namespace, name)
	if index_of(context, namespace, name) then
		return false
	end
	table.insert(load(), { context = context, namespace = namespace, name = name })
	save()
	return true
end

function M.remove(context, namespace, name)
	local i = index_of(context, namespace, name)
	if not i then
		return false
	end
	table.remove(entries, i)
	save()
	return true
end

--- Namespaces present in a context's watchlist, so the refresh can batch one
-- kubectl call per namespace instead of one per deployment.
function M.namespaces(context)
	local seen, out = {}, {}
	for _, e in ipairs(M.list(context)) do
		if not seen[e.namespace] then
			seen[e.namespace] = true
			table.insert(out, e.namespace)
		end
	end
	return out
end

return M
