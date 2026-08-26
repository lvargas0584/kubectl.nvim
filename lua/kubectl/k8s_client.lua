-- The only module that shells out to kubectl. Everything here is async
-- (vim.system) so a live dashboard never blocks the editor. Callbacks always
-- receive (result, err) and are scheduled on the main loop.
local M = {}

--- Translate raw kubectl stderr into something a human can act on.
local function friendly(err)
	err = err or ""
	if err:match("connection refused") then
		return "Cannot connect to the Kubernetes cluster"
	elseif err:match("context.*not found") or err:match("current%-context") then
		return "No context configured. Try 'kubectl config get-contexts'"
	elseif err:match("[Ff]orbidden") then
		return "Insufficient permissions for this resource"
	elseif err:match("NotFound") or err:match("not found") then
		return "Resource not found in the cluster"
	elseif err:match("timed out") or err:match("timeout") then
		return "Request timed out. The cluster may be slow or unreachable"
	end
	return (err:gsub("^%s*(.-)%s*$", "%1"))
end

--- Run kubectl with the given argv. cb(stdout, err)
-- @param args table: argv after "kubectl"
-- @param cb function
function M.run(args, cb)
	local cmd = { "kubectl" }
	vim.list_extend(cmd, args)
	local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
		vim.schedule(function()
			if res.code ~= 0 then
				cb(nil, friendly(res.stderr ~= "" and res.stderr or res.stdout))
			else
				cb(res.stdout, nil)
			end
		end)
	end)
	if not ok then
		vim.schedule(function()
			cb(nil, "kubectl is not on PATH (" .. tostring(err) .. ")")
		end)
	end
end

--- Run kubectl -o json and decode. cb(table, err)
local function run_json(args, cb)
	M.run(args, function(out, err)
		if not out then
			return cb(nil, err)
		end
		local ok, json = pcall(vim.json.decode, out)
		if not ok or type(json) ~= "table" then
			return cb(nil, "Could not parse kubectl output")
		end
		cb(json, nil)
	end)
end

--- Current context name and its default namespace, in one call.
-- cb({ context = string, namespace = string }, err)
function M.context_info(cb)
	run_json({ "config", "view", "--minify", "-o", "json" }, function(json, err)
		if not json then
			return cb(nil, err)
		end
		local ctx = json.contexts and json.contexts[1]
		cb({
			context = ctx and ctx.name or "unknown",
			namespace = ctx and ctx.context and ctx.context.namespace or "default",
		}, nil)
	end)
end

--- cb(list of namespace names, err)
function M.get_namespaces(cb)
	run_json({ "get", "namespaces", "-o", "json" }, function(json, err)
		if not json then
			return cb(nil, err)
		end
		local names = {}
		for _, ns in ipairs(json.items or {}) do
			table.insert(names, ns.metadata.name)
		end
		cb(names, nil)
	end)
end

--- cb(list of Deployment objects, err)
function M.get_deployments(ns, cb)
	run_json({ "get", "deployments", "-n", ns, "-o", "json" }, function(json, err)
		cb(json and (json.items or {}) or nil, err)
	end)
end

--- Deployments and pods of one namespace, fetched in parallel and joined.
-- Two calls are needed because AGE, restarts and failure reasons only exist on
-- the pods, while images and replica counts live on the deployment.
-- cb({ deployments = {...}, pods = {...} }, err)
function M.snapshot(ns, cb)
	local out, pending, first_err = {}, 2, nil
	local function done()
		pending = pending - 1
		if pending > 0 then
			return
		end
		if not out.deployments or not out.pods then
			return cb(nil, first_err or "Failed to read namespace " .. ns)
		end
		cb(out, nil)
	end

	M.get_deployments(ns, function(items, err)
		out.deployments = items
		first_err = first_err or err
		done()
	end)
	run_json({ "get", "pods", "-n", ns, "-o", "json" }, function(json, err)
		out.pods = json and (json.items or {}) or nil
		first_err = first_err or err
		done()
	end)
end

-- ---------------------------------------------------------------------------
-- Mutations. All of them target deployment/<name>, never a pod.
-- ---------------------------------------------------------------------------

function M.restart(ns, name, cb)
	M.run({ "rollout", "restart", "deployment/" .. name, "-n", ns }, cb)
end

function M.scale(ns, name, replicas, cb)
	M.run({ "scale", "deployment/" .. name, "--replicas=" .. replicas, "-n", ns }, cb)
end

function M.set_image(ns, name, container, image, cb)
	M.run({ "set", "image", "deployment/" .. name, container .. "=" .. image, "-n", ns }, cb)
end

function M.describe(ns, name, cb)
	M.run({ "describe", "deployment/" .. name, "-n", ns }, cb)
end

function M.events(ns, name, cb)
	M.run({
		"events",
		"-n",
		ns,
		"--for",
		"deployment/" .. name,
	}, cb)
end

--- Build the argv for a log stream. Kept here so k8s_client stays the single
-- place that knows kubectl's surface; ui/logs.lua only runs it.
function M.logs_cmd(ns, pod, container, tail)
	local cmd = { "kubectl", "logs", "-f", "--tail", tostring(tail), pod, "-n", ns }
	if container then
		vim.list_extend(cmd, { "-c", container })
	end
	return cmd
end

--- Newest running pod of a deployment, for log streaming. cb(pod_name, err)
function M.newest_pod(ns, name, cb)
	M.snapshot(ns, function(snap, err)
		if not snap then
			return cb(nil, err)
		end
		local deploy
		for _, d in ipairs(snap.deployments) do
			if d.metadata.name == name then
				deploy = d
				break
			end
		end
		if not deploy then
			return cb(nil, "Deployment " .. name .. " does not exist in " .. ns)
		end
		local pods = require("kubectl.format").select_pods(snap.pods, deploy.spec.selector.matchLabels)
		local newest
		for _, p in ipairs(pods) do
			if not newest or p.metadata.creationTimestamp > newest.metadata.creationTimestamp then
				newest = p
			end
		end
		if not newest then
			return cb(nil, name .. " has no pods (scaled to 0?)")
		end
		cb(newest.metadata.name, nil)
	end)
end

return M
