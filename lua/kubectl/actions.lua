-- Every mutating action. All of them go through confirm() first, and all of
-- them target deployment/<name> — never a pod.
local M = {}

local conf = require("kubectl.config")
local client = require("kubectl.k8s_client")
local state = require("kubectl.state")
local wl = require("kubectl.watchlist")
local fmt = require("kubectl.format")

local function notify(msg, level)
	vim.notify("kubectl: " .. msg, level or vim.log.levels.INFO)
end

local function dashboard()
	return require("kubectl.ui.dashboard")
end

--- Blocking yes/no. Defaults to "No" so a stray <CR> never fires an action.
function M.confirm(msg)
	if not conf.get().confirm_actions then
		return true
	end
	return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
end

--- Report the outcome of a mutation and refresh the watchlist.
local function done(ok_msg)
	return function(out, err)
		if not out then
			return notify(err, vim.log.levels.ERROR)
		end
		notify(ok_msg)
		dashboard().refresh()
	end
end

function M.remove(row)
	if not M.confirm(string.format("Remove %s/%s from the watchlist?", row.ns, row.name)) then
		return
	end
	wl.remove(state.context, row.ns, row.name)
	notify(row.name .. " removed from the watchlist")
	dashboard().refresh()
end

function M.restart(row)
	if not M.confirm(string.format("Restart deployment %s in %s?", row.name, row.ns)) then
		return
	end
	client.restart(row.ns, row.name, done("restart rolled out: " .. row.name))
end

--- @param replicas number|nil: prompts when nil
function M.scale(row, replicas)
	local function apply(n)
		if not M.confirm(string.format("Scale %s in %s to %d replicas?", row.name, row.ns, n)) then
			return
		end
		client.scale(row.ns, row.name, n, done(string.format("%s scaled to %d", row.name, n)))
	end

	if replicas then
		return apply(replicas)
	end
	vim.ui.input({ prompt = "Replicas for " .. row.name .. ": ", default = row.ready:match("/(%d+)") }, function(input)
		local n = tonumber(input)
		if not n or n < 0 then
			return
		end
		apply(math.floor(n))
	end)
end

--- Apply a full image reference to the deployment's first container.
local function apply_image(row, image)
	if not row.container then
		return notify("container name for " .. row.name .. " is unknown", vim.log.levels.ERROR)
	end
	if image == row.image then
		return notify("image unchanged")
	end
	if not M.confirm(string.format("Change the image of %s in %s?\n\n  %s\n→ %s", row.name, row.ns, row.image, image)) then
		return
	end
	client.set_image(row.ns, row.name, row.container, image, done("image updated: " .. image))
end

--- Edit the whole image reference, prefilled with the current one.
function M.set_image(row)
	vim.ui.input({ prompt = "Image: ", default = row.image }, function(input)
		if input and input ~= "" then
			apply_image(row, input)
		end
	end)
end

--- Edit only the tag, keeping the repository.
function M.set_version(row)
	local repo, _, tag = fmt.parse_image(row.image)
	if repo == "" then
		return notify("could not read the current image of " .. row.name, vim.log.levels.ERROR)
	end
	vim.ui.input({ prompt = "Version (" .. repo .. ":): ", default = tag }, function(input)
		if input and input ~= "" then
			apply_image(row, repo .. ":" .. input)
		end
	end)
end

function M.events(row)
	client.events(row.ns, row.name, function(out, err)
		if not out then
			return notify(err, vim.log.levels.ERROR)
		end
		dashboard().show_text("events/" .. row.name, out)
	end)
end

function M.describe(row)
	client.describe(row.ns, row.name, function(out, err)
		if not out then
			return notify(err, vim.log.levels.ERROR)
		end
		dashboard().show_text("describe/" .. row.name, out)
	end)
end

return M
