-- assets/wezterm.lua（yazipane 用の WezTerm 設定）のテスト。
-- WezTerm の API（wezterm / mux / ペイン / タブ / ウィンドウ）を偽物に差し替えて読み込み、
-- イベント（gui-startup / update-status / format-window-title）やキーの処理を呼んで、何をするかを確かめる。
-- WezTerm 本体での動作の確認ではない（そちらは task smoke と手作業）。
--
--   lua Yazipane.Tests/lua/wezterm_test.lua <wezterm.lua のパス>
--   （task test から tools/test.ps1 経由で実行される）

local CONFIG = assert(arg[1], "wezterm.lua のパスを指定してください")
local real_getenv = os.getenv
local HERE = arg[0]:match("^(.*)[/\\]") or "."
local T = dofile(HERE .. "/testing.lua")("Lua（WezTerm）")
local test, eq = T.test, T.eq

-- ---- 偽の WezTerm ----

--- ペインの偽物。fg は前面のプロセスの名前（nil なら無し）
local function new_pane(id, opts)
	opts = opts or {}
	local p = { id = id, fg = opts.fg or "yazi.exe", pid = opts.pid or (1000 + id), left = opts.left or 0, width = opts.width or 40 }
	function p:pane_id() return self.id end
	function p:get_foreground_process_info()
		if not self.fg then
			return nil
		end
		return { executable = "C:\\bin\\" .. self.fg, pid = self.pid, argv = { self.fg } }
	end
	function p:activate() self.tab_.active = self end
	function p:tab() return self.tab_ end
	return p
end

--- タブの偽物（ペインは左から順に並べる）。set_zoomed は WezTerm と同じく、今のペインを最大化する
local function new_tab(panes)
	local t = { panes = panes, active = panes[1], zoomed = nil }
	for _, p in ipairs(panes) do
		p.tab_ = t
	end
	function t:tab_id() return 7 end
	function t:panes_with_info()
		local list = {}
		for i, p in ipairs(self.panes) do
			list[i] = { pane = p, is_active = self.active == p, is_zoomed = self.zoomed == p, left = p.left, width = p.width, title = p.title }
		end
		return list
	end
	function t:set_zoomed(on) self.zoomed = on and self.active or nil end
	return t
end

--- wezterm.lua を新しく読み込む。opts.env: 環境変数 / opts.alive: 生きている PID → true（既定はすべて生きている）
local function load(opts)
	opts = opts or {}
	local env = opts.env or { YAZIPANE_YA = "ya.exe", YAZIPANE_LEFT_ID = "11", YAZIPANE_RIGHT_ID = "12" }
	local ctx = { handlers = {}, background = {}, focus_background = {}, timers = {}, toasts = {}, errors = {}, actions = {}, spawned = {} }
	local wezterm = {
		GLOBAL = {},
		home_dir = "C:\\home",
		config_builder = function() return {} end,
		on = function(name, f) ctx.handlers[name] = f end,
		action_callback = function(f) return { callback = f } end,
		background_child_process = function(args)
			local target = args[6] and args[6]:match("^focus%-") and ctx.focus_background or ctx.background
			target[#target + 1] = table.concat(args, " ")
		end,
		log_error = function(msg) ctx.errors[#ctx.errors + 1] = msg end,
		procinfo = {
			get_info_for_pid = function(pid)
				if opts.alive and not opts.alive[pid] then
					return nil
				end
				return { pid = pid }
			end,
		},
		time = { call_after = function(_, f) ctx.timers[#ctx.timers + 1] = f end },
		-- act.X { ... } → { action = "X", arg = { ... } }
		action = setmetatable({}, { __index = function(_, name) return function(arg) return { action = name, arg = arg } end end }),
		mux = {
			spawn_window = function(args)
				local left = new_pane(0)
				ctx.spawned.left = args
				function left:split(a)
					ctx.spawned.right = a
					local right = new_pane(1)
					ctx.tab = new_tab({ left, right })
					return right
				end
				local window = { gui_window = function() return { maximize = function() ctx.maximized = true end } end }
				return nil, left, window
			end,
		},
	}
	ctx.wezterm = wezterm
	package.loaded["wezterm"] = wezterm
	-- 環境変数はイベントの処理（gui-startup など）でも読むので、次に load するまで偽物のままにする
	os.getenv = function(k) return env[k] end
	local ok, result = pcall(dofile, CONFIG)
	assert(ok, result)
	ctx.config = result

	--- 左右のペインを用意する（gui-startup と同じく、ペイン ID → yazi のクライアント ID を GLOBAL に置く）
	function ctx.panes(left_opts, right_opts)
		local l, r = new_pane(0, left_opts), new_pane(1, right_opts or { left = 41 })
		ctx.tab = new_tab({ l, r })
		wezterm.GLOBAL.yazipane_ids = { ["0"] = "11", ["1"] = "12" }
		return l, r
	end
	ctx.window = {
		active_tab = function() return ctx.tab end,
		toast_notification = function(_, _, msg) ctx.toasts[#ctx.toasts + 1] = msg end,
		perform_action = function(_, action, pane) ctx.actions[#ctx.actions + 1] = { action = action, pane = pane } end,
	}
	--- update-status（定期的な確認の 1 回分）
	function ctx.update()
		ctx.handlers["update-status"](ctx.window, nil)
	end
	--- 自分のキー割り当て（key / mods）の処理
	function ctx.key(key, mods)
		for _, k in ipairs(ctx.config.keys) do
			if k.key == key and k.mods == mods then
				return k.action
			end
		end
	end
	return ctx
end

-- ---- 起動時 ----

test("起動時: 左右の yazi に互いのクライアント ID と設定の場所を渡す", function()
	local ctx = load { env = {
		YAZIPANE_YAZI = "yazi.exe", YAZIPANE_LEFT_DIR = "C:\\L", YAZIPANE_RIGHT_DIR = "C:\\R",
		YAZIPANE_LEFT_ID = "11", YAZIPANE_RIGHT_ID = "12", YAZIPANE_CONFIG_HOME = "C:\\gen", YAZIPANE_YA = "ya.exe",
	} }
	ctx.handlers["gui-startup"]()
	local l, r = ctx.spawned.left, ctx.spawned.right
	eq(table.concat(l.args, " "), "yazi.exe --client-id 11 C:\\L", "左の yazi")
	eq(table.concat(r.args, " "), "yazi.exe --client-id 12 C:\\R", "右の yazi")
	eq(l.set_environment_variables.YAZIPANE_PEER, "12", "左の相手")
	eq(r.set_environment_variables.YAZIPANE_PEER, "11", "右の相手")
	eq(l.set_environment_variables.YAZIPANE_SIDE, "left", "左")
	eq(l.set_environment_variables.YAZIPANE_YA, "ya.exe", "フォーカス通知の可否")
	-- WezTerm がレジストリの値で上書きするので、別名で受け取って詰め替える
	eq(l.set_environment_variables.YAZI_CONFIG_HOME, "C:\\gen", "yazi の設定の場所")
	eq(ctx.wezterm.GLOBAL.yazipane_ids["1"], "12", "ペイン ID → クライアント ID")
	eq(ctx.maximized, true, "最大化する")
end)

test("起動時: 前回のウィンドウの位置を復元するときは最大化しない", function()
	local ctx = load { env = { YAZIPANE_RESTORE_WINDOW = "1" } }
	ctx.handlers["gui-startup"]()
	eq(ctx.maximized, nil, "最大化しない")
end)

-- ---- エディタなどを開いている間だけ 1 画面にする ----

test("自動 1 画面: yazi 以外が続いたら 1 画面にし、yazi に戻ったら 2 画面に戻す", function()
	local ctx = load()
	local l = ctx.panes()
	l.fg = "nvim.exe"
	ctx.update()
	eq(ctx.tab.zoomed, nil, "1 回目ではまだ切り替えない")
	ctx.update()
	eq(ctx.tab.zoomed, l, "2 回続いたら、そのペインを 1 画面にする")
	l.fg = "yazi.exe"
	ctx.update()
	eq(ctx.tab.zoomed, nil, "yazi に戻ったら 2 画面に戻す")
end)

test("自動 1 画面: 右のペインで開いたら右のペインを 1 画面にする", function()
	local ctx = load()
	local _, r = ctx.panes()
	r.fg = "nvim.exe"
	ctx.update()
	ctx.update()
	eq(ctx.tab.zoomed, r, "右のペイン")
end)

test("自動 1 画面: 一瞬だけのもの・yazi が裏で起動するものでは切り替えない", function()
	local ctx = load()
	local l = ctx.panes()
	l.fg = "pandoc.exe"
	ctx.update()
	l.fg = "yazi.exe"
	ctx.update()
	for _, name in ipairs({ "git.exe", "file.exe", "yazipane.exe", "ya.exe" }) do
		l.fg = name
		ctx.update()
		ctx.update()
	end
	eq(ctx.tab.zoomed, nil, "切り替えない")
end)

test("自動 1 画面: 終了したプロセスが前面として残っていても数えない", function()
	local ctx = load { alive = {} }
	local l = ctx.panes()
	l.fg = "nvim.exe"
	ctx.update()
	ctx.update()
	eq(ctx.tab.zoomed, nil, "切り替えない")
end)

test("自動 1 画面: 開く前から自分で 1 画面にしていたら、閉じても 1 画面のまま", function()
	local ctx = load()
	local l = ctx.panes()
	ctx.tab:set_zoomed(true)
	l.fg = "nvim.exe"
	ctx.update()
	ctx.update()
	l.fg = "yazi.exe"
	ctx.update()
	eq(ctx.tab.zoomed, l, "1 画面のまま")
end)

test("自動 1 画面: 開いている途中で自分で 2 画面に戻したら、閉じるまでそのまま", function()
	local ctx = load()
	local l = ctx.panes()
	l.fg = "nvim.exe"
	ctx.update()
	ctx.update()
	ctx.tab:set_zoomed(false)
	ctx.update()
	ctx.update()
	eq(ctx.tab.zoomed, nil, "もう一度 1 画面にはしない")
	l.fg = "yazi.exe"
	ctx.update()
	l.fg = "nvim.exe"
	ctx.update()
	ctx.update()
	eq(ctx.tab.zoomed, l, "閉じてからもう一度開いたら、また 1 画面にする")
end)

-- ---- yazi への列の切り替えの通知 ----

test("フォーカス: 変化したときだけ両ペインに通知する", function()
	local ctx = load()
	local _, right = ctx.panes()
	ctx.update()
	eq(table.concat(ctx.focus_background, ";"), "ya.exe emit-to 11 plugin yazipane focus-on;ya.exe emit-to 12 plugin yazipane focus-off")
	ctx.focus_background = {}
	ctx.update()
	eq(#ctx.focus_background, 0, "変化しなければ再送しない")
	right:activate()
	ctx.update()
	eq(table.concat(ctx.focus_background, ";"), "ya.exe emit-to 11 plugin yazipane focus-off;ya.exe emit-to 12 plugin yazipane focus-on")
end)

test("1 画面にしたら、最大化したペインの yazi を本来の 3 列にし、2 画面に戻したら両方を 2 画面用にする", function()
	local ctx = load()
	ctx.panes()
	ctx.update()
	eq(#ctx.background, 0, "起動直後（2 画面）は伝えない")
	ctx.tab:set_zoomed(true)
	ctx.update()
	eq(table.concat(ctx.background, ";"), "ya.exe emit-to 11 plugin yazipane layout-single", "1 画面")
	ctx.background = {}
	ctx.tab:set_zoomed(false)
	ctx.update()
	eq(table.concat(ctx.background, ";"),
		"ya.exe emit-to 11 plugin yazipane layout-dual;ya.exe emit-to 12 plugin yazipane layout-dual", "2 画面")
	ctx.background = {}
	ctx.update()
	eq(#ctx.background, 0, "変わらなければ伝えない")
end)

test("ya.exe が無ければ、列を切り替えられないことを知らせる", function()
	local ctx = load { env = {} }
	ctx.panes()
	ctx.update()
	eq(#ctx.toasts, 0, "起動直後は知らせない")
	ctx.tab:set_zoomed(true)
	ctx.update()
	ctx.tab:set_zoomed(false)
	ctx.update()
	eq(#ctx.background, 0, "ya は呼ばない")
	eq(#ctx.toasts, 1, "1 回だけ知らせる")
end)

-- ---- 定期的な確認のタイマー ----

test("最初の update-status でタイマーを始め、動いている間は始め直さない", function()
	local ctx = load()
	ctx.panes()
	ctx.update()
	eq(#ctx.timers, 1, "タイマーを始める")
	ctx.timers[1]()
	eq(#ctx.timers, 2, "動くたびに次を予約する")
	ctx.update()
	eq(#ctx.timers, 2, "動いている間は始め直さない")
end)

test("タイマーが止まっていたら（最後に動いてから 2 秒より前）始め直し、古いタイマーは止まる", function()
	local ctx = load()
	ctx.panes()
	ctx.update()
	local old = ctx.timers[1]
	ctx.wezterm.GLOBAL.yazipane_timer_beat = os.time() - 10
	ctx.update()
	eq(#ctx.timers, 2, "始め直す")
	old()
	eq(#ctx.timers, 2, "古いタイマーは次を予約しない")
end)

-- ---- 左右を同じ幅に戻す（Ctrl+Shift+E） ----

test("Ctrl+Shift+E: 左のペインの右端を動かして同じ幅にする", function()
	local ctx = load()
	local l = ctx.panes({ width = 30 }, { left = 31, width = 50 })
	ctx.key("e", "CTRL|SHIFT").callback(ctx.window, l)
	local a = ctx.actions[1]
	eq(a.action.action, "AdjustPaneSize", "動作")
	eq(a.action.arg[1] .. " " .. a.action.arg[2], "Right 10", "向きと量")
	eq(a.pane, l, "左のペイン")
end)

test("Ctrl+Shift+E: 1 画面のとき・同じ幅のときは何もしない", function()
	local ctx = load()
	local l = ctx.panes({ width = 40 }, { left = 41, width = 40 })
	ctx.key("e", "CTRL|SHIFT").callback(ctx.window, l)
	ctx.tab:set_zoomed(true)
	ctx.key("e", "CTRL|SHIFT").callback(ctx.window, l)
	eq(#ctx.actions, 0, "何もしない")
end)

-- ---- ウィンドウタイトル ----

test("ウィンドウタイトル: 左右のフォルダ名。1 画面のときは表示中のフォルダ名", function()
	local ctx = load()
	local title = ctx.handlers["format-window-title"]
	local panes = { { left = 41, title = "Yazi: right", is_zoomed = false }, { left = 0, title = "Yazi: left", is_zoomed = false } }
	eq(title({ active_pane = panes[2] }, nil, nil, panes, nil), "yazipane — left  │  right", "2 画面")
	panes[1].is_zoomed = true
	eq(title({ active_pane = panes[1] }, nil, nil, panes, nil), "yazipane [1画面] — right", "1 画面")
end)

-- ---- 普段の設定との合成 ----

--- 普段の WezTerm 設定を一時ファイルに書いて、その設定で読み込む
local function load_with_user(source)
	local path = (real_getenv("TEMP") or ".") .. "\\yazipane-wezterm-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e9)) .. ".lua"
	local f = assert(io.open(path, "w"))
	f:write(source)
	f:close()
	local ctx = load { env = { YAZIPANE_USER_WEZTERM = path } }
	os.remove(path)
	return ctx
end

test("普段の設定: フォントなどは普段のものを使い、yazipane に必要なものだけ上書きする", function()
	local ctx = load_with_user([[return { font_size = 12, enable_scroll_bar = true, enable_kitty_keyboard = true, inactive_pane_hsb = { brightness = 0.9 } }]])
	eq(ctx.config.font_size, 12, "普段の設定")
	eq(ctx.config.enable_scroll_bar, false, "yazipane が上書きする")
	eq(ctx.config.enable_kitty_keyboard, false, "拡張キー入力を無効にする")
	eq(ctx.config.automatically_reload_config, false, "自動では読み直さない")
	eq(ctx.config.inactive_pane_hsb.brightness, 0.9, "普段の設定にあればそちら")
end)

test("普段のキー割り当て: 残すが、yazipane のキーと重なるもの（mods の書き順が違っても）は yazipane を優先する", function()
	local ctx = load_with_user([[return { keys = {
		{ key = "a", mods = "CTRL", action = "user-a" },
		{ key = "Tab", mods = "CTRL", action = "user-tab" },
		{ key = "e", mods = "SHIFT|CTRL", action = "user-e" },
	} }]])
	local actions = {}
	for _, k in ipairs(ctx.config.keys) do
		actions[#actions + 1] = type(k.action) == "string" and k.action or (k.action.action or "callback")
	end
	eq(table.concat(actions, ","), "user-a,ActivatePaneDirection,ActivatePaneDirection,callback", "キー割り当て")
end)

test("普段の設定: 読めなければ記録して、yazipane の設定だけで動く", function()
	local ctx = load_with_user([[error("壊れている")]])
	eq(#ctx.errors, 1, "記録する")
	eq(ctx.config.enable_scroll_bar, false, "yazipane の設定")
end)

test("普段の設定が無くても、yazipane のキーだけで動く", function()
	local ctx = load()
	eq(#ctx.config.keys, 3, "Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+Shift+E")
	eq(ctx.config.inactive_pane_hsb.brightness, 0.5, "非アクティブなペインを暗くする")
end)

T.finish()
