-- Mutable session state: the active context/namespace and every background
-- job or timer we own, so VimLeavePre can shut them all down.
local M = {}

M.context = nil -- current kube context name
M.namespace = nil -- default namespace for `a` and the namespace picker
M.jobs = {} -- job handle -> label
M.timer = nil -- the auto-refresh timer

function M.register_job(handle, label)
	M.jobs[handle] = label or true
end

function M.unregister_job(handle)
	M.jobs[handle] = nil
end

function M.stop_job(handle)
	if handle and M.jobs[handle] then
		pcall(function()
			handle:kill(15)
		end)
		M.jobs[handle] = nil
	end
end

function M.stop_all_jobs()
	for handle, _ in pairs(M.jobs) do
		pcall(function()
			handle:kill(15)
		end)
	end
	M.jobs = {}
end

function M.stop_timer()
	if M.timer then
		pcall(function()
			M.timer:stop()
			M.timer:close()
		end)
		M.timer = nil
	end
end

function M.cleanup()
	M.stop_all_jobs()
	M.stop_timer()
end

return M
