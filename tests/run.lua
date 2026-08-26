-- Checks for the logic that can break silently. Run with:  nvim -l tests/run.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fmt = require("kubectl.format")
local passed = 0

local function check(cond, label)
	if not cond then
		error(label, 2)
	end
	passed = passed + 1
end

local function eq(got, want, label)
	if got ~= want then
		error(string.format("%s: esperaba %q, obtuve %q", label, tostring(want), tostring(got)), 2)
	end
	passed = passed + 1
end

-- --- age ------------------------------------------------------------------
local NOW = { year = 2026, month = 2, day = 18, hour = 18, min = 36, sec = 18 }

eq(fmt.age("2026-02-18T18:36:18Z", NOW), "0s", "age: mismo instante")
eq(fmt.age("2026-02-18T18:35:48Z", NOW), "30s", "age: segundos")
eq(fmt.age("2026-02-18T18:01:18Z", NOW), "35m", "age: minutos")
eq(fmt.age("2026-02-18T16:36:18Z", NOW), "2h", "age: horas")
eq(fmt.age("2026-02-15T18:36:18Z", NOW), "3d", "age: días")
eq(fmt.age("2026-03-01T00:00:00Z", NOW), "0s", "age: futuro se satura en 0s")
eq(fmt.age("no es una fecha", NOW), "?", "age: timestamp inválido")
eq(fmt.age(nil, NOW), "?", "age: nil")
-- Cruza el límite de mes y de año, donde el cálculo de días suele romperse.
eq(fmt.age("2025-12-31T18:36:18Z", { year = 2026, month = 1, day = 2, hour = 18, min = 36, sec = 18 }), "2d", "age: cruce de año")

-- --- parse_image ----------------------------------------------------------
local function img(image, repo, variant, tag)
	local r, v, t = fmt.parse_image(image)
	eq(r, repo, "parse_image repo: " .. image)
	eq(v, variant, "parse_image variant: " .. image)
	eq(t, tag, "parse_image tag: " .. image)
end

img("acme.corp/pagos_jvm:dev_1.4.2", "acme.corp/pagos_jvm", "jvm", "dev_1.4.2")
img("acme.corp/pagos_native:1.2.0", "acme.corp/pagos_native", "native", "1.2.0")
img("acme.corp/pagos-jvm:feature_RPLAT-32456", "acme.corp/pagos-jvm", "jvm", "feature_RPLAT-32456")
-- El puerto del registry contiene ':' y engaña a un parser ingenuo.
img("reg.local:5000/app_jvm:dev_1.0", "reg.local:5000/app_jvm", "jvm", "dev_1.0")
img("reg.local:5000/app", "reg.local:5000/app", nil, "")
img("nginx", "nginx", nil, "")
img("nginx:1.25", "nginx", nil, "1.25")
img("acme/app@sha256:abc123", "acme/app", nil, "")
img("", "", nil, "")
-- Un sufijo que no es una variante conocida no debe reportarse como tal.
img("acme/app_worker:1.0", "acme/app_worker", nil, "1.0")

-- --- fit ------------------------------------------------------------------
eq(fmt.fit("abc", 5), "abc  ", "fit: rellena")
eq(#fmt.fit("un-nombre-de-deployment-muy-largo", 10), 10, "fit: trunca al ancho exacto")
eq(fmt.fit(nil, 3), "   ", "fit: nil")

-- --- select_pods ----------------------------------------------------------
local pods = {
	{ metadata = { name = "a-1", labels = { app = "a" }, creationTimestamp = "2026-02-18T18:00:00Z" } },
	{ metadata = { name = "b-1", labels = { app = "b" }, creationTimestamp = "2026-02-18T18:00:00Z" } },
	{ metadata = { name = "a-2", labels = { app = "a", tier = "x" }, creationTimestamp = "2026-02-18T18:30:00Z" } },
}
eq(#fmt.select_pods(pods, { app = "a" }), 2, "select_pods: por etiqueta")
eq(#fmt.select_pods(pods, { app = "a", tier = "x" }), 1, "select_pods: selector compuesto")
eq(#fmt.select_pods(pods, {}), 0, "select_pods: selector vacío no lo empareja todo")
eq(#fmt.select_pods(pods, nil), 0, "select_pods: sin selector")

-- --- build_row ------------------------------------------------------------
local deploy = {
	metadata = { name = "pagos-api", namespace = "qa" },
	spec = {
		replicas = 2,
		selector = { matchLabels = { app = "a" } },
		template = { spec = { containers = { { name = "pagos", image = "acme.corp/pagos_jvm:dev_1.4.2" } } } },
	},
	status = { readyReplicas = 2 },
}

local row = fmt.build_row(deploy, pods, NOW)
eq(row.name, "pagos-api", "build_row: nombre")
eq(row.variant, "jvm", "build_row: variante")
eq(row.version, "dev_1.4.2", "build_row: versión")
eq(row.container, "pagos", "build_row: contenedor")
eq(row.ready, "2/2", "build_row: ready")
eq(row.age, "6m", "build_row: edad del pod más nuevo, no del deployment")
eq(row.severity, "ok", "build_row: sano")
eq(row.reason, nil, "build_row: sin motivo de fallo")

-- Menos réplicas listas de las deseadas => aviso, no error.
local degraded = vim.deepcopy(deploy)
degraded.status.readyReplicas = 1
eq(fmt.build_row(degraded, pods, NOW).severity, "warn", "build_row: degradado")

-- Un pod atascado en ImagePullBackOff manda sobre el conteo de réplicas.
local broken_pods = vim.deepcopy(pods)
broken_pods[1].status = { containerStatuses = { { restartCount = 3, state = { waiting = { reason = "ImagePullBackOff" } } } } }
local broken = fmt.build_row(deploy, broken_pods, NOW)
eq(broken.severity, "error", "build_row: severidad de fallo")
eq(broken.reason, "ImagePullBackOff", "build_row: motivo")
eq(broken.restarts, 3, "build_row: reinicios (máximo entre pods)")

-- ContainerCreating es transitorio y no debe pintarse como error.
local starting = vim.deepcopy(pods)
starting[1].status = { containerStatuses = { { restartCount = 0, state = { waiting = { reason = "ContainerCreating" } } } } }
eq(fmt.build_row(deploy, starting, NOW).reason, nil, "build_row: ContainerCreating se ignora")

-- Escalado a 0: sin pods, sin edad, y no es un error.
local zero = vim.deepcopy(deploy)
zero.spec.replicas = 0
zero.status.readyReplicas = 0
local zrow = fmt.build_row(zero, {}, NOW)
eq(zrow.ready, "0/0", "build_row: escalado a cero")
eq(zrow.age, "-", "build_row: sin pods, sin edad")
eq(zrow.severity, "ok", "build_row: cero réplicas deseadas no es un fallo")

-- --- render_row -----------------------------------------------------------
local w = fmt.widths({ row, broken, zrow })
eq(#fmt.render_row(row, w), #fmt.header(w), "render_row: alineado con la cabecera")
check(fmt.render_row(broken, w):match("ImagePullBackOff$"), "render_row: el motivo va al final")
-- Las columnas crecen con el contenido en vez de truncarlo.
local wide = fmt.widths({ { ns = "dev-02-vizix-cloud", name = "a", variant = "-",
                            version = "feature_RPLAT-32456", ready = "1/1", age = "2h", restarts = 0 } })
eq(wide.ns, #"dev-02-vizix-cloud", "widths: el namespace largo cabe entero")
eq(wide.version, #"feature_RPLAT-32456", "widths: la versión larga cabe entera")
eq(fmt.widths({}).name, #"DEPLOYMENT", "widths: mínimo = la propia etiqueta")
eq(fmt.widths({ { ns = string.rep("x", 99) } }).ns, 24, "widths: techo por columna")
passed = passed + 1

-- --- watchlist ------------------------------------------------------------
local wl = require("kubectl.watchlist")
wl.path = vim.fn.tempname() .. "/watchlist.json"
wl.reload()

eq(wl.add("ctx1", "qa", "pagos-api"), true, "watchlist: alta")
eq(wl.add("ctx1", "qa", "pagos-api"), false, "watchlist: sin duplicados")
wl.add("ctx1", "dev", "catalogo")
wl.add("ctx2", "qa", "otro")

eq(#wl.list("ctx1"), 2, "watchlist: filtrada por contexto")
eq(wl.list("ctx1")[1].namespace, "dev", "watchlist: ordenada por namespace")
eq(#wl.namespaces("ctx1"), 2, "watchlist: namespaces únicos para agrupar el refresco")

wl.reload() -- fuerza releer desde disco
eq(#wl.list("ctx1"), 2, "watchlist: persiste entre cargas")
eq(wl.remove("ctx1", "qa", "pagos-api"), true, "watchlist: baja")
eq(wl.remove("ctx1", "qa", "pagos-api"), false, "watchlist: baja de algo inexistente")
wl.reload()
eq(#wl.list("ctx1"), 1, "watchlist: la baja persiste")

-- --- streaming de logs ----------------------------------------------------
-- kubectl entrega trozos, no líneas: la última línea de cada trozo puede venir
-- partida. Se sustituye el comando por uno local para ejercitarlo sin cluster.
local logs = require("kubectl.ui.logs")
local client = require("kubectl.k8s_client")
local conf = require("kubectl.config")
conf.setup({ log_max_lines = 6 })

client.logs_cmd = function()
	-- Sale en dos escrituras y la segunda no acaba en salto de línea.
	return { "sh", "-c", "printf 'l1\nl2\nl'; sleep 0.05; printf '3\nl4\nl5\ncolgando'" }
end

local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].modifiable = false
local pane = { ns = "qa", deploy = "d", pod = "p", tail = 10, follow = false, partial = "", buf = buf }
logs.panes[buf] = pane
logs.stream(pane)

check(vim.wait(5000, function()
	local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
	return last:match("stream ended") ~= nil
end, 20), "el stream no terminó")

local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
eq(#out, 6, "logs: recortado a log_max_lines")
eq(out[1], "l2", "logs: se descartan las líneas más antiguas, no las nuevas")
-- "l" y "3" llegaron en escrituras distintas: deben reensamblarse en "l3".
eq(out[2], "l3", "logs: línea partida entre trozos reensamblada")
check(not vim.tbl_contains(out, "l"), "logs: se emitió media línea")
eq(out[5], "colgando", "logs: la última línea sin salto se vuelca al salir")
logs.stop(pane)

-- --- dashboard y ventanas -------------------------------------------------
-- Todo esto corre sin cluster: los datos se inyectan en render() a mano.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
require("kubectl").setup({ auto_refresh = 0 })
check(vim.fn.exists(":Kubectl") == 2, ":Kubectl no se registró")

local dash = require("kubectl.ui.dashboard")
local state = require("kubectl.state")
local wl = require("kubectl.watchlist")
wl.path = vim.fn.tempname() .. "/w2.json"
wl.reload()

dash.open()
check(dash.is_open(), "el dashboard no se abrió")
local lines = vim.api.nvim_buf_get_lines(dash.buf, 0, -1, false)
check(lines[1]:match("^NS"), "falta la cabecera: " .. vim.inspect(lines[1]))
check(lines[2]:match("watchlist empty"), "falta el placeholder: " .. vim.inspect(lines[2]))
check(vim.wo[dash.win].winfixwidth, "winfixwidth no está puesto")

-- Abrir un panel en el área de logs debe devolverle su ancho a la watchlist.
local scratch = vim.api.nvim_create_buf(false, true)
local pane_win = logs.place(scratch, false)
check(pane_win and vim.api.nvim_win_is_valid(pane_win), "no se creó el panel")
check(vim.api.nvim_get_current_win() == dash.win, "el foco debe quedarse en la watchlist")
local want = math.min(dash.content_width + 2, math.floor(vim.o.columns * 0.6))
check(vim.api.nvim_win_get_width(dash.win) == want,
  "ancho tras el split: " .. vim.api.nvim_win_get_width(dash.win) .. " != " .. want)
check(logs.focus(), "<Tab> no llega al panel de logs")
vim.api.nvim_set_current_win(dash.win)

-- Render con datos falsos: sin cluster, ejercita el camino completo de pintado.
state.context = "ctx-test"
wl.add("ctx-test", "qa", "pagos-api")
wl.add("ctx-test", "qa", "fantasma")
dash.render({
  qa = {
    deployments = { {
      metadata = { name = "pagos-api", namespace = "qa" },
      spec = { replicas = 1, selector = { matchLabels = { app = "p" } },
               template = { spec = { containers = { { name = "pagos", image = "acme/pagos_jvm:dev_1.4.2" } } } } },
      status = { readyReplicas = 1 },
    } },
    pods = { { metadata = { name = "pagos-api-x", namespace = "qa", labels = { app = "p" },
                            creationTimestamp = os.date("!%Y-%m-%dT%H:%M:%SZ") } } },
  },
})
lines = vim.api.nvim_buf_get_lines(dash.buf, 0, -1, false)
-- Ordenadas por namespace y luego por nombre: fantasma va antes que pagos-api.
check(lines[2]:match("fantasma") and lines[2]:match("NotFound"), "deployment ausente mal pintado: " .. lines[2])
check(lines[3]:match("pagos%-api") and lines[3]:match("jvm") and lines[3]:match("dev_1%.4%.2"), "fila mala: " .. lines[3])
check(dash.rows[3].name == "pagos-api", "el mapeo línea->fila está desalineado")
check(dash.rows[3].container == "pagos", "la fila debe llevar el contenedor para 'set image'")

-- --- el cursor debe caer sobre una fila, no sobre la cabecera --------------
-- Si se queda en la línea 1, toda acción contextual responde "no deployment on
-- this line" y el dashboard parece muerto.
check(vim.api.nvim_win_get_cursor(dash.win)[1] > 1, "el cursor se quedó en la cabecera")
check(dash.current_row() ~= nil, "no hay fila enfocada tras renderizar")

-- Al quedarse sin filas el cursor no puede apuntar a una fila inexistente.
wl.remove("ctx-test", "qa", "pagos-api")
wl.remove("ctx-test", "qa", "fantasma")
dash.render({})
check(dash.rows[vim.api.nvim_win_get_cursor(dash.win)[1]] == nil, "watchlist vacía: no debe haber fila")

wl.add("ctx-test", "qa", "pagos-api")
dash.render({ qa = { deployments = {}, pods = {} } })
check(dash.current_row() ~= nil, "el cursor no volvió a una fila tras repoblar")

-- --- acciones globales alcanzables desde un panel de logs ------------------
-- `a`, `n`, `r` y `?` no dependen de la fila enfocada: deben funcionar también
-- con el foco en los logs, que es donde el usuario pasa el rato.
-- Neovim normaliza el lhs al devolverlo (<C-c> sale como <C-C>), así que se
-- compara en minúsculas.
local function keymaps_of(b)
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
		out[m.lhs:lower()] = true
	end
	return out
end

local shared = keymaps_of(scratch)
for _, k in ipairs({ "a", "n", "r", "?", "x", "<Tab>" }) do
	check(shared[k:lower()], "falta el atajo compartido " .. k .. " en el panel")
end
-- Un panel de `describe` no transmite nada: grep y tail no le corresponden.
check(not shared["g"], "un panel de detalle no debe tener grep")

-- Un panel de logs real sí los tiene. Se falsean pod y comando para no
-- depender del cluster.
client.newest_pod = function(_, _, cb)
	cb("pod-falso", nil)
end
logs.open({ ns = "qa", name = "svc", container = nil }, true)
check(vim.wait(3000, function()
	for b, pane in pairs(logs.panes) do
		if pane.pod == "pod-falso" and vim.api.nvim_buf_is_valid(b) then
			return true
		end
	end
	return false
end, 20), "logs.open no creó el panel")

local real_pane_buf
for b, pane in pairs(logs.panes) do
	if pane.pod == "pod-falso" then
		real_pane_buf = b
	end
end
local real = keymaps_of(real_pane_buf)
for _, k in ipairs({ "a", "n", "r", "?", "x", "<Tab>", "g", "t", "f", "<C-c>" }) do
	check(real[k:lower()], "falta el atajo " .. k .. " en un panel de logs")
end

-- Los atajos existen sobre el buffer del dashboard.
local maps = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(dash.buf, "n")) do maps[m.lhs] = true end
for _, k in ipairs({ "<CR>", "o", "a", "d", "R", "i", "v", "s", "0", "n", "e", "K", "T", "r", "q", "?", "<Tab>" }) do
  check(maps[k], "falta el atajo " .. k)
end

-- La confirmación por defecto es "No": confirm_actions activo y sin respuesta => aborta.
local actions = require("kubectl.actions")
require("kubectl.config").setup({ confirm_actions = false })
check(actions.confirm("da igual") == true, "confirm_actions=false debería pasar de largo")

dash.close()
check(not dash.is_open(), "el dashboard no se cerró")
check(vim.tbl_isempty(state.jobs), "quedaron jobs vivos")
check(state.timer == nil, "quedó un timer vivo")


-- --- layout = "split": convive con el buffer en el que estabas --------------
vim.cmd("enew")
local code_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { "mi código" })
require("kubectl.config").setup({ layout = "split", auto_refresh = 0 })
local tabs_before = vim.fn.tabpagenr("$")

dash.open()
check(dash.is_open(), "no abrió en modo split")
check(vim.fn.tabpagenr("$") == tabs_before, "modo split no debe crear una pestaña")
check(#vim.api.nvim_tabpage_list_wins(0) == 2, "esperaba watchlist + el buffer original")
check(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[2]) == code_buf, "se perdió el buffer original")
dash.close()
check(vim.api.nvim_buf_is_valid(code_buf), "cerrar el dashboard no debe tocar tu buffer")
check(#vim.api.nvim_tabpage_list_wins(0) == 1, "quedó una ventana huérfana")


print(string.format("ok  %d comprobaciones", passed))
