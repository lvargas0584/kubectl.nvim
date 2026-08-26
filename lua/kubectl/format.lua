-- Pure formatting helpers: no vim API, so tests/run.lua can require this directly.
local M = {}

-- Days-since-epoch algorithm. Avoids os.time(), which is locale/timezone
-- dependent, because the AGE column must match `kubectl get pods` exactly.
local function utc_epoch(y, m, d, H, Mi, S)
	if m < 3 then
		y = y - 1
		m = m + 12
	end
	local days = math.floor(365.25 * y) + math.floor(30.6001 * (m + 1)) + d - 719561
	return days * 86400 + H * 3600 + Mi * 60 + S
end

--- Format an RFC3339 timestamp as a kubectl-style age ("35m", "2h", "3d").
-- @param ts string|nil: RFC3339 timestamp
-- @param now table|nil: os.date("!*t") table, injectable for tests
-- @return string
function M.age(ts, now)
	if not ts then
		return "?"
	end
	local y, m, d, H, Mi, S = ts:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
	if not y then
		return "?"
	end
	local started = utc_epoch(tonumber(y), tonumber(m), tonumber(d), tonumber(H), tonumber(Mi), tonumber(S))
	local n = now or os.date("!*t")
	local diff = utc_epoch(n.year, n.month, n.day, n.hour, n.min, n.sec) - started

	if diff < 0 then
		return "0s"
	elseif diff < 60 then
		return diff .. "s"
	elseif diff < 3600 then
		return math.floor(diff / 60) .. "m"
	elseif diff < 86400 then
		return math.floor(diff / 3600) .. "h"
	end
	return math.floor(diff / 86400) .. "d"
end

--- Split an image reference into repo, variant and tag.
-- The last colon is only a tag separator when it comes after the last slash,
-- otherwise it is a registry port: "reg.local:5000/app_jvm:dev_1.0".
-- @param image string
-- @return string repo, string|nil variant ("jvm"|"native"), string tag
function M.parse_image(image)
	if not image or image == "" then
		return "", nil, ""
	end
	local repo = image:gsub("@.*$", "") -- drop any digest
	local tag = ""
	local colon = repo:match("^.*():")
	local slash = repo:match("^.*()/") or 0
	if colon and colon > slash then
		tag = repo:sub(colon + 1)
		repo = repo:sub(1, colon - 1)
	end
	local variant = repo:match("[_%-](%a+)$")
	if variant ~= "jvm" and variant ~= "native" then
		variant = nil
	end
	return repo, variant, tag
end

--- Pad or truncate to an exact width. k8s names and tags are ASCII, so byte
-- length equals display width and the padding stays aligned.
function M.fit(s, w)
	s = tostring(s or "")
	if #s <= w then
		return s .. string.rep(" ", w - #s)
	end
	return s:sub(1, w - 1) .. "~"
end

--- Does a pod carry every label in the deployment's selector?
local function matches(pod, selector)
	local labels = (pod.metadata or {}).labels or {}
	for k, v in pairs(selector) do
		if labels[k] ~= v then
			return false
		end
	end
	return true
end

--- Pods belonging to a deployment, by its spec.selector.matchLabels.
function M.select_pods(pods, selector)
	local out = {}
	if not selector or next(selector) == nil then
		return out
	end
	for _, p in ipairs(pods or {}) do
		if matches(p, selector) then
			table.insert(out, p)
		end
	end
	return out
end

-- Transient states that are not worth alarming about.
local BENIGN = {
	ContainerCreating = true,
	PodInitializing = true,
}

--- First real failure reason across a deployment's pods, if any.
local function failure_reason(pods)
	for _, p in ipairs(pods) do
		for _, cs in ipairs((p.status or {}).containerStatuses or {}) do
			local waiting = (cs.state or {}).waiting
			if waiting and waiting.reason and not BENIGN[waiting.reason] then
				return waiting.reason
			end
			local term = (cs.state or {}).terminated
			if term and term.reason and term.reason ~= "Completed" then
				return term.reason
			end
		end
		local phase = (p.status or {}).phase
		if phase == "Failed" or phase == "Unknown" then
			return phase
		end
	end
	return nil
end

--- Build the dashboard row data for one deployment.
-- @param deploy table: a Deployment JSON object
-- @param pods table: the namespace's pod list (filtered here by selector)
-- @param now table|nil: injectable clock for tests
-- @return table: { ns, name, variant, version, image, container, ready, age,
--                  restarts, reason, severity }
function M.build_row(deploy, pods, now)
	local meta = deploy.metadata or {}
	local spec = deploy.spec or {}
	local status = deploy.status or {}
	local containers = ((spec.template or {}).spec or {}).containers or {}
	local image = containers[1] and containers[1].image or ""
	local _, variant, tag = M.parse_image(image)

	local desired = spec.replicas or 0
	local ready = status.readyReplicas or 0
	local mine = M.select_pods(pods, spec.selector and spec.selector.matchLabels)

	-- Newest pod drives AGE: that is the signal that a restart actually landed.
	local newest, restarts = nil, 0
	for _, p in ipairs(mine) do
		local created = (p.metadata or {}).creationTimestamp
		if created and (not newest or created > newest) then
			newest = created
		end
		local sum = 0
		for _, cs in ipairs((p.status or {}).containerStatuses or {}) do
			sum = sum + (cs.restartCount or 0)
		end
		if sum > restarts then
			restarts = sum
		end
	end

	local reason = failure_reason(mine)
	local severity = "ok"
	if reason then
		severity = "error"
	elseif ready < desired then
		severity = "warn"
	end

	return {
		ns = meta.namespace or "",
		name = meta.name or "",
		variant = variant or "-",
		version = tag ~= "" and tag or "-",
		image = image,
		container = containers[1] and containers[1].name or nil,
		ready = string.format("%d/%d", ready, desired),
		age = newest and M.age(newest, now) or "-",
		restarts = restarts,
		reason = reason,
		severity = severity,
	}
end

-- Minimum width of each column: its own label.
local LABELS = {
	ns = "NS",
	name = "DEPLOYMENT",
	variant = "VAR",
	version = "VERSION",
	ready = "READY",
	age = "AGE",
	restarts = "RST",
}
local ORDER = { "ns", "name", "variant", "version", "ready", "age", "restarts" }
-- Ceilings, so one absurd name cannot push every other column off screen.
local CEILING = { ns = 24, name = 32, variant = 7, version = 26, ready = 7, age = 5, restarts = 4 }

--- Column widths that fit the given rows. Namespace and deployment names vary
-- far too much between clusters for fixed widths to be readable.
function M.widths(rows)
	local w = {}
	for key, label in pairs(LABELS) do
		w[key] = #label
	end
	for _, r in ipairs(rows or {}) do
		for _, key in ipairs(ORDER) do
			w[key] = math.max(w[key], #tostring(r[key] or ""))
		end
	end
	for key, max in pairs(CEILING) do
		w[key] = math.min(w[key], max)
	end
	return w
end

local function line(values, w)
	local cells = {}
	for _, key in ipairs(ORDER) do
		table.insert(cells, M.fit(values[key], w[key]))
	end
	return table.concat(cells, " ")
end

function M.header(w)
	return line(LABELS, w)
end

--- Render a row as a line. The failure reason is appended after the last
-- column and deliberately does not participate in the width calculation.
function M.render_row(row, w)
	local out = line(row, w)
	if row.reason then
		out = out .. " " .. row.reason
	end
	return out
end

--- A row for a watchlist entry whose deployment is missing from the cluster.
function M.missing_row(entry)
	return {
		ns = entry.namespace,
		name = entry.name,
		variant = "-",
		version = "-",
		ready = "-",
		age = "-",
		restarts = 0,
		reason = "NotFound",
		severity = "error",
	}
end

return M
