-- yazipane.yazi/main.lua のテスト。
-- yazi の API（ya / ps / cx / Command など）を偽物に差し替えて main.lua を読み込み、
-- entry に操作名を渡したときに「どの yazipane.exe のサブコマンドを呼ぶか」「何を emit / 通知するか」を確かめる。
-- yazi 本体での表示や動作の確認ではない（そちらは task smoke と手作業）。
--
--   lua Yazipane.Tests/lua/plugin_test.lua <main.lua のパス>
--   （task test から tools/test.ps1 経由で実行される）

local PLUGIN = assert(arg[1], "main.lua のパスを指定してください")
local T = dofile((arg[0]:match("^(.*)[/\\]") or ".") .. "/testing.lua")("Lua（プラグイン）")
local test, eq = T.test, T.eq

-- ---- 偽の yazi ----

--- main.lua を新しく読み込み、偽の yazi を用意する。
--- opts.env: 環境変数 / opts.output: yazipane.exe の結果 { code, stdout, stderr }（関数なら引数ごとに返す）
--- opts.cwd / opts.hovered / opts.files / opts.peer_files: yazi の状態
local function load(opts)
	opts = opts or {}
	local ctx = { notes = {}, emits = {}, commands = {}, state = {}, subs = {}, remote = {}, pubs = {} }
	local env = opts.env or {}

	ya = {
		sync = function(f) return function(...) return f(ctx.state, ...) end end,
		notify = function(t) ctx.notes[#ctx.notes + 1] = t.level .. ":" .. t.content end,
		emit = function(name, args) ctx.emits[#ctx.emits + 1] = { name = name, args = args } end,
		sleep = function()
			if ctx.state.peer_cwd and ctx.remote["yazipane-cwd"] and not opts.no_peer_response then
				ctx.remote["yazipane-cwd"](ctx.state.peer_cwd)
			end
		end,
		confirm = function() return opts.confirm ~= false end,
		which = function(args)
			ctx.which = args
			if type(opts.which) == "table" then return table.remove(opts.which, 1) end
			return opts.which
		end,
	}
	ps = {
		pub_to = function(peer, kind, value) ctx.pubs[#ctx.pubs + 1] = { peer = peer, kind = kind, value = value } end,
		sub = function(kind, f) ctx.subs[kind] = f end,
		sub_remote = function(kind, f) ctx.remote[kind] = f end,
	}
	ui = {
		render = function() end,
		Line = function(s) return s end,
		Text = function(s) return { wrap = function(self) return self end } end,
		Wrap = { YES = 1 },
	}
	Status = { RIGHT = 1, children_add = function() end }
	Modal = opts.modal and {
		children_add = function(_, component) ctx.modal = component return 1 end,
		children_remove = function(_, id) ctx.removed_modal = id end,
	} or nil
	rt = { mgr = { ratio = { 0, 3, 2 } } }
	cx = {
		active = {
			current = { cwd = opts.cwd or "C:\\work", hovered = opts.hovered, files = opts.files or {} },
			selected = opts.selected or {},
		},
	}
	Url = function(s) return s end
	fs = { read_dir = function() return opts.peer_files or {} end }
	Command = setmetatable({ PIPED = 1 }, {
		__call = function()
			local c, args = {}, nil
			function c:arg(a) args = a return self end
			function c:stdout() return self end
			function c:stderr() return self end
			function c:output()
				ctx.commands[#ctx.commands + 1] = table.concat(args, " ")
				local o = type(opts.output) == "function" and opts.output(args) or opts.output or {}
				if o.error then
					error(o.error)
				end
				return { status = { code = o.code or 0 }, stdout = o.stdout or "", stderr = o.stderr or "" }
			end
			return c
		end,
	})

	local getenv = os.getenv
	os.getenv = function(k) return env[k] end
	local M = dofile(PLUGIN)
	M.setup(ctx.state)
	os.getenv = getenv

	function ctx.run(action)
		M.entry(ctx.state, { args = { action } })
	end
	function ctx.emitted(name)
		local list = {}
		for _, e in ipairs(ctx.emits) do
			if e.name == name then
				list[#list + 1] = e.args
			end
		end
		return list
	end
	return ctx
end

-- yazipane から起動された状態（exe と反対ペインあり）
local function yazipane(opts)
	opts = opts or {}
	opts.env = opts.env or { YAZIPANE_EXE = "yazipane.exe", YAZIPANE_PEER = "2", YAZIPANE_SIDE = "left" }
	local ctx = load(opts)
	ctx.state.peer_cwd = opts.peer_cwd or "C:\\peer"
	return ctx
end

--- yazi の Url の偽物（tostring でパス、parent で親フォルダの Url）
local url_meta = {}
url_meta.__tostring = function(u) return u.path end
url_meta.__index = function(u, k)
	if k == "parent" then
		local parent = u.path:match("^(.*)\\[^\\]+$")
		return parent and setmetatable({ path = parent }, url_meta) or nil
	end
end
local function url(path)
	return setmetatable({ path = path }, url_meta)
end

local function file(name, mtime, is_dir)
	return { name = name, url = url("C:\\work\\" .. name), cha = { is_dir = is_dir or false, mtime = mtime } }
end

--- 選択（cx.active.selected）。パスの一覧から Url の一覧を作る
local function selected(...)
	local list = {}
	for _, p in ipairs({ ... }) do
		list[#list + 1] = url(p)
	end
	return list
end

-- ---- テスト ----

test("Alt+N: 左右どちらからでも同じ順序のフォルダで新しいウィンドウを開く", function()
	local left = yazipane { cwd = "C:\\left folder", peer_cwd = "D:\\right folder" }
	left.run("new-window")
	eq(left.commands[1], "--new-window C:\\left folder D:\\right folder")
	local right = yazipane { cwd = "D:\\right folder", peer_cwd = "C:\\left folder",
		env = { YAZIPANE_EXE = "yazipane.exe", YAZIPANE_PEER = "2", YAZIPANE_SIDE = "right" } }
	right.run("new-window")
	eq(right.commands[1], "--new-window C:\\left folder D:\\right folder")
end)

test("Alt+N: 反対ペインの応答が無ければ起動しない", function()
	local ctx = yazipane { no_peer_response = true }
	ctx.run("new-window")
	eq(#ctx.commands, 0)
	eq(ctx.notes[1], "error:反対ペインの場所が分かりません")
end)

test("Alt+N: 起動に失敗したら通知する", function()
	local ctx = yazipane { output = { code = 1, stderr = "起動失敗" } }
	ctx.run("new-window")
	eq(ctx.notes[1], "error:新しいウィンドウを起動できません: 起動失敗")
end)

test("反対ペインが無いと連携の操作は警告だけ", function()
	local ctx = load { env = { YAZIPANE_EXE = "yazipane.exe" } }
	ctx.run("swap")
	eq(ctx.notes[1], "warn:yazipane から起動された yazi ではありません")
	eq(#ctx.commands, 0, "呼んだコマンドの数")
end)

test("不明な操作はエラーを通知する", function()
	local ctx = yazipane()
	ctx.run("nope")
	eq(ctx.notes[1], "error:不明な操作です: nope")
end)

test("YAZIPANE_EXE が無ければ exe を呼ばずに通知する", function()
	local ctx = load { env = {} }
	ctx.run("drives")
	eq(ctx.notes[1], "error:YAZIPANE_EXE が設定されていません")
	eq(#ctx.commands, 0, "呼んだコマンドの数")
end)

test("F5（確認なし）: 反対ペインへ --transfer copy し、選択を解除する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { stdout = "1 0 0" } }
	ctx.run("copy-now")
	eq(ctx.commands[1], "--transfer copy C:\\peer C:\\work\\a.txt")
	eq(#ctx.emitted("escape"), 1, "選択の解除")
	eq(ctx.notes[1], "info:1 件を反対ペインへコピーしました")
end)

test("F6: 選択があれば選択を対象にする", function()
	local ctx = yazipane { hovered = file("a.txt"), selected = selected("C:\\work\\b.txt", "C:\\work\\c.txt"),
		output = { stdout = "2 0 0" } }
	ctx.run("move-now")
	eq(ctx.commands[1], "--transfer move C:\\peer C:\\work\\b.txt C:\\work\\c.txt")
	eq(ctx.notes[1], "info:2 件を反対ペインへ移動しました")
end)

test("F5: 確認で取り消したら何もしない", function()
	local ctx = yazipane { hovered = file("a.txt"), confirm = false }
	ctx.run("copy")
	eq(#ctx.commands, 0, "呼んだコマンドの数")
end)

test("F5: 両方のペインが同じフォルダなら警告だけ", function()
	local ctx = yazipane { hovered = file("a.txt"), peer_cwd = "C:\\work" }
	ctx.run("copy-now")
	eq(ctx.notes[1], "warn:両方のペインが同じディレクトリです")
	eq(#ctx.commands, 0, "呼んだコマンドの数")
end)

test("F5: 途中で取り消されたら（終了コード 4）中止を通知する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { code = 4, stdout = "0 0 0" } }
	ctx.run("copy-now")
	eq(ctx.notes[1], "warn:反対ペインへコピーを中止しました（0 件は完了）")
	eq(#ctx.emitted("escape"), 0, "選択の解除")
end)

test("F5: スキップ・失敗した件数も通知する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { stdout = "2 1 0" } }
	ctx.run("copy-now")
	eq(ctx.notes[1], "info:2 件を反対ペインへコピーしました（1 件はスキップ）")

	ctx = yazipane { hovered = file("a.txt"), output = { stdout = "1 0 1" } }
	ctx.run("copy-now")
	eq(ctx.notes[1], "warn:1 件を反対ペインへコピーしました（1 件は失敗）")

	ctx = yazipane { hovered = file("a.txt"), output = { stdout = "0 2 0" } }
	ctx.run("copy-now")
	eq(ctx.notes[1], "warn:反対ペインへコピーしたものはありません（2 件はスキップ）")
end)

test("Ctrl+V: 切り取ったものを貼り付けたら移動として通知する", function()
	local ctx = yazipane { output = { stdout = "move 2 0 0" } }
	ctx.run("paste")
	eq(ctx.commands[1], "--paste C:\\work")
	eq(ctx.notes[1], "info:2 件を移動しました")
end)

test("Ctrl+V: クリップボードにファイルが無ければ（終了コード 5）警告する", function()
	local ctx = yazipane { output = { code = 5, stderr = "クリップボードにファイルがありません" } }
	ctx.run("paste")
	eq(ctx.notes[1], "warn:クリップボードにファイルがありません")
end)

test("Alt+D: 選んだドライブへ cd する", function()
	local ctx = yazipane { which = 2, output = { stdout = "C:\\\tシステム\nD:\\\tデータ" } }
	ctx.run("drives")
	eq(ctx.commands[1], "--drives")
	eq(ctx.emitted("cd")[1][1], "D:\\", "移動先")
end)

test("Alt+D: 独自の一覧を使い、選択後に片付ける", function()
	local ctx = yazipane { modal = true, which = 1, output = { stdout = "C:\\\t空き 10 GB" } }
	ctx.run("drives")
	eq(ctx.which.silent, true, "既定の一覧は表示しない")
	eq(ctx.which.cands[1].on, "c", "選択キー")
	eq(ctx.removed_modal, 1, "一覧を削除")
	eq(ctx.emitted("cd")[1][1], "C:\\", "移動先")
end)

test("Alt+D: キャンセルしたら一覧を片付け、移動しない", function()
	local ctx = yazipane { modal = true, output = { stdout = "C:\\\t空き 10 GB" } }
	ctx.run("drives")
	eq(ctx.removed_modal, 1, "一覧を削除")
	eq(#ctx.emitted("cd"), 0, "移動しない")
end)

test("Alt+D: 下矢印と Enter で次のドライブを選ぶ", function()
	local ctx = yazipane { modal = true, which = { 4, 5 }, output = { stdout = "C:\\\tシステム\nD:\\\tデータ" } }
	ctx.run("drives")
	eq(ctx.emitted("cd")[1][1], "D:\\", "移動先")
	eq(ctx.removed_modal, 1, "一覧を削除")
end)

test("Alt+D: 上下の端で選択は範囲外へ移動しない", function()
	local ctx = yazipane { modal = true, which = { 3, 4, 4, 5 }, output = { stdout = "C:\\\tシステム\nD:\\\tデータ" } }
	ctx.run("drives")
	eq(ctx.emitted("cd")[1][1], "D:\\", "移動先")
end)

test("Alt+E: yazi の shell で、カーソル位置があれば選択した状態で、無ければフォルダを開く", function()
	local ctx = yazipane { hovered = file("a.txt") }
	ctx.run("explorer")
	local shell = ctx.emitted("shell")[1]
	eq(shell[1], "explorer /select,%h", "コマンド")
	eq(shell.orphan, true, "orphan")
	eq(#ctx.commands, 0, "yazipane.exe は呼ばない")
	ctx = yazipane()
	ctx.run("explorer")
	eq(ctx.emitted("shell")[1][1], "explorer .", "コマンド")
end)

test("空き容量: ドライブごとに覚えてステータスバーに使う", function()
	local ctx = yazipane { cwd = "D:\\data", output = { stdout = "空き 1 GB / 2 GB" } }
	ctx.run("free")
	eq(ctx.commands[1], "--free D:\\")
	eq(ctx.state.free["D:\\"].text, "空き 1 GB / 2 GB")
end)

test("空き容量: 取り直しの途中で cd が続いても、依頼は 1 回だけ", function()
	-- setup のときに 1 回依頼し、その返事（set_free）が来る前に cd が 2 回続く
	local ctx = yazipane()
	ctx.subs.cd()
	ctx.subs.cd()
	local plugins = ctx.emitted("plugin")
	eq(#plugins, 1, "依頼の数")
	eq(plugins[1][2], "free", "依頼した操作")
end)

test("空き容量: ネットワークパスでは取らない", function()
	local ctx = yazipane { cwd = "\\\\server\\share" }
	ctx.run("free")
	eq(#ctx.commands, 0, "呼んだコマンドの数")
end)

test("Alt+C: こちらにしか無いもの・こちらの方が新しいファイルを選択する", function()
	local ctx = yazipane {
		files = { file("only.txt", 10), file("newer.txt", 20), file("same.txt", 5), file("Older.TXT", 1), file("dir", 99, true) },
		peer_files = {
			{ name = "newer.txt", cha = { is_dir = false, mtime = 10 } },
			{ name = "same.txt", cha = { is_dir = false, mtime = 5 } },
			{ name = "older.txt", cha = { is_dir = false, mtime = 9 } }, -- 大文字と小文字は区別しない
			{ name = "dir", cha = { is_dir = true, mtime = 1 } },        -- フォルダは有無だけを比べる
		},
	}
	ctx.run("compare")
	local revealed = {}
	for _, a in ipairs(ctx.emitted("reveal")) do
		revealed[#revealed + 1] = a[1]
	end
	eq(table.concat(revealed, ","), "C:\\work\\only.txt,C:\\work\\newer.txt", "選択したファイル")
	eq(#ctx.emitted("toggle"), 2, "選択した数")
	eq(ctx.notes[1], "info:こちらにしか無い 1 件、こちらの方が新しい 1 件を選択しました（F5 で反対ペインへコピー）")
end)

test("1 画面: 普段の列の比率にし、2 画面に戻すと元の比率に戻す", function()
	local ctx = load { env = { YAZIPANE_NATIVE_RATIO = "1,3,4", YAZIPANE_PEER = "2" } }
	ctx.run("layout-single")
	eq(table.concat(rt.mgr.ratio, ","), "1,3,4", "1 画面の比率")
	ctx.run("layout-dual")
	eq(table.concat(rt.mgr.ratio, ","), "0,3,2", "2 画面の比率")
end)

test("q: 自分も終了する", function()
	local ctx = yazipane()
	ctx.run("quit")
	eq(#ctx.emitted("quit"), 1, "quit")
end)

test("Alt+H: キー一覧に keymap.toml の yazipane のキーがすべて載っている", function()
	-- main.lua の HELP と keymap.toml がずれないようにする（キーを足したら両方を更新する）
	local dir = PLUGIN:match("^(.*)[/\\]plugins[/\\]")
	local f = assert(io.open(dir .. "/keymap.toml", "r"))
	local keymap = f:read("a")
	f:close()
	local src = assert(io.open(PLUGIN, "r"))
	local help = src:read("a"):match("local HELP = (%b{})")
	src:close()
	local names = {
		["<F5>"] = "F5", ["<F6>"] = "F6", ["<A-o>"] = "Alt+O", ["<A-s>"] = "Alt+S", ["<A-i>"] = "Alt+I", ["<A-x>"] = "Alt+X", ["<A-n>"] = "Alt+N",
		["<A-d>"] = "Alt+D", ["<A-e>"] = "Alt+E", ["<S-F10>"] = "Shift+F10", ["<C-c>"] = "Ctrl+C", ["<C-v>"] = "Ctrl+V",
		["<A-p>"] = "Alt+P", ["<A-l>"] = "Alt+L", ["<A-c>"] = "Alt+C", ["<A-h>"] = "Alt+H", ["q"] = "q", ["="] = "=",
	}
	for on in keymap:gmatch('on%s*=%s*"([^"]+)"') do
		local name = names[on]
		if not name then
			error("テストの names に " .. on .. " の表記を足してください")
		end
		-- キー名の一部だけに一致しないよう、直後に英数字が続かないものだけを数える
		local found, from = false, 1
		while true do
			local s, e = help:find(name, from, true)
			if not s then
				break
			end
			if not help:sub(e + 1, e + 1):match("%w") then
				found = true
				break
			end
			from = e + 1
		end
		if not found then
			error("HELP に " .. name .. " がありません")
		end
	end
end)

-- ---- 右クリックメニュー ----

--- 右クリックメニュー（--context-menu）の結果と、続けて呼ぶサブコマンドの結果
local function menu_returns(action, rest)
	return function(args)
		if args[1] == "--context-menu" then
			return { stdout = action }
		end
		return rest or { stdout = "1 0 0" }
	end
end

test("右クリック: カーソル位置が選択に含まれなければ、選択を解除してカーソル位置だけ", function()
	local ctx = yazipane { hovered = file("a.txt"), selected = selected("C:\\work\\b.txt"), output = menu_returns("") }
	ctx.run("menu")
	eq(ctx.commands[1], "--context-menu C:\\work\\a.txt")
	eq(#ctx.emitted("escape"), 1, "選択の解除")
end)

test("右クリック: カーソル位置が選択に含まれれば選択全体。別のフォルダのものは外して件数を通知する", function()
	local ctx = yazipane {
		hovered = file("a.txt"),
		selected = selected("C:\\work\\a.txt", "C:\\work\\b.txt", "C:\\other\\c.txt"),
		output = menu_returns(""),
	}
	ctx.run("menu")
	eq(ctx.commands[1], "--context-menu C:\\work\\a.txt C:\\work\\b.txt")
	eq(ctx.notes[1], "warn:別のフォルダにある 1 件は右クリックメニューの対象外です")
	eq(#ctx.emitted("escape"), 0, "選択は残す")
end)

test("右クリック: カーソル位置が無ければ選択を対象にする（空のフォルダで選択だけ残っているとき）", function()
	local ctx = yazipane { selected = selected("C:\\work\\a.txt"), output = menu_returns("") }
	ctx.run("menu")
	eq(ctx.commands[1], "--context-menu C:\\work\\a.txt")
end)

test("右クリック: 対象が無ければメニューを出さない", function()
	local ctx = yazipane()
	ctx.run("menu")
	eq(#ctx.commands, 0, "呼んだコマンドの数")
end)

test("右クリック: 「反対ペインへコピー」は確認を出さず、メニューの対象をそのまま渡す", function()
	-- confirm = false なので、確認を出していたら何もしないはず
	local ctx = yazipane { hovered = file("a.txt"), confirm = false, output = menu_returns("copy") }
	ctx.run("menu")
	eq(ctx.commands[2], "--transfer copy C:\\peer C:\\work\\a.txt")
	eq(ctx.notes[1], "info:1 件を反対ペインへコピーしました")
end)

test("右クリック: 「名前の変更」は yazi の名前変更、「パスをコピー」は yazi の copy path", function()
	local ctx = yazipane { hovered = file("a.txt"), output = menu_returns("rename") }
	ctx.run("menu")
	eq(ctx.emitted("rename")[1].cursor, "before_ext", "rename")
	ctx = yazipane { hovered = file("a.txt"), output = menu_returns("copypath") }
	ctx.run("menu")
	eq(ctx.emitted("copy")[1][1], "path", "copy")
end)

test("右クリック: メニューを出せなければエラーを通知する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { code = 1, stderr = "boom" } }
	ctx.run("menu")
	eq(ctx.notes[1], "error:メニューの表示に失敗しました: boom")
end)

-- ---- クリップボード / ドラッグ ----

test("Ctrl+C: 選択（無ければカーソル位置）をクリップボードにコピーし、件数を通知する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { stdout = "1" } }
	ctx.run("clipboard")
	eq(ctx.commands[1], "--clipboard C:\\work\\a.txt")
	eq(ctx.notes[1], "info:1 件をクリップボードにコピーしました（ほかのアプリで Ctrl+V）")
end)

test("Ctrl+C: コピーできなければエラーを通知する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { code = 1, stderr = "使用中です" } }
	ctx.run("clipboard")
	eq(ctx.notes[1], "error:クリップボードにコピーできません: 使用中です")
end)

test("Alt+X: ファイルを切り取りとしてクリップボードに登録する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { stdout = "1" } }
	ctx.run("clipboard-cut")
	eq(ctx.commands[1], "--clipboard-cut C:\\work\\a.txt")
	eq(ctx.notes[1], "info:1 件をクリップボードに切り取りしました（ほかのアプリで Ctrl+V）")
end)

test("ドラッグ: 1 回だけ開始し、終わったらまたドラッグできる", function()
	local ctx = yazipane { hovered = file("a.txt") }
	ctx.state.dragging = true
	ctx.run("drag")
	eq(#ctx.commands, 0, "ドラッグ中は始めない")
	ctx.state.dragging = false
	ctx.run("drag")
	eq(ctx.commands[1], "--drag C:\\work\\a.txt")
	eq(ctx.state.dragging, false, "終わったらドラッグ中ではない")
end)

test("ドラッグ: 途中でエラーになってもドラッグ中のまま残らない", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { error = "起動できない" } }
	ctx.run("drag")
	eq(ctx.state.dragging, false, "ドラッグ中ではない")
end)

test("ドラッグ: ドラッグできなければ（終了コード 1）エラーを通知する", function()
	local ctx = yazipane { hovered = file("a.txt"), output = { code = 1, stderr = "boom" } }
	ctx.run("drag")
	eq(ctx.notes[1], "error:ドラッグできません: boom")
end)

-- ---- 反対ペインとの連携 ----

--- 送ったもの（ps.pub_to）のうち kind のもの
local function pubs(ctx, kind)
	local list = {}
	for _, p in ipairs(ctx.pubs) do
		if p.kind == kind then
			list[#list + 1] = p
		end
	end
	return list
end

test("=: 反対ペインに今のフォルダへ cd してもらう", function()
	local ctx = yazipane()
	ctx.run("push")
	local p = pubs(ctx, "yazipane-cd")[1]
	eq(p.peer, 2, "相手")
	eq(p.value, "C:\\work", "移動先")
end)

test("Alt+O: 反対ペインのフォルダへ cd する", function()
	local ctx = yazipane()
	ctx.run("pull")
	eq(ctx.emitted("cd")[1][1], "C:\\peer", "移動先")
end)

test("Alt+S: 左右のフォルダを入れ替える。同じフォルダなら何もしない", function()
	local ctx = yazipane()
	ctx.run("swap")
	eq(pubs(ctx, "yazipane-cd")[1].value, "C:\\work", "反対ペインの移動先")
	eq(ctx.emitted("cd")[1][1], "C:\\peer", "こちらの移動先")
	ctx = yazipane { peer_cwd = "C:\\work" }
	ctx.run("swap")
	eq(#pubs(ctx, "yazipane-cd") + #ctx.emitted("cd"), 0, "何もしない")
end)

test("Alt+I: カーソル位置のフォルダを反対ペインで開く。フォルダでなければ警告", function()
	local ctx = yazipane { hovered = file("sub", nil, true) }
	ctx.run("open-peer")
	eq(pubs(ctx, "yazipane-cd")[1].value, "C:\\work\\sub", "移動先")
	ctx = yazipane { hovered = file("a.txt") }
	ctx.run("open-peer")
	eq(ctx.notes[1], "warn:ディレクトリにカーソルを合わせてください")
end)

test("反対ペインの場所が分からなければエラーを通知する", function()
	local ctx = yazipane { hovered = file("a.txt") }
	ctx.state.peer_cwd = nil
	ctx.run("copy-now")
	eq(ctx.notes[1], "error:反対ペインの場所が分かりません")
end)

test("反対ペインの応答がなければ古い場所へ移動しない", function()
	local ctx = yazipane { hovered = file("a.txt"), no_peer_response = true }
	ctx.run("move-now")
	eq(#ctx.commands, 0)
	eq(ctx.notes[1], "error:反対ペインの場所が分かりません")
end)

test("反対ペインから届いた cd / 終了に従う", function()
	local ctx = yazipane()
	ctx.remote["yazipane-cd"]("C:\\there")
	ctx.remote["yazipane-quit"]()
	eq(ctx.emitted("cd")[1][1], "C:\\there", "移動先")
	eq(#ctx.emitted("quit"), 1, "quit")
end)

test("q: 反対ペインにも終了を伝える", function()
	local ctx = yazipane()
	ctx.run("quit")
	eq(#pubs(ctx, "yazipane-quit"), 1, "終了の通知")
end)

-- ---- 列の表示 ----

test("Alt+P: プレビュー列を隠して反対ペインにも伝え、もう一度で元の幅に戻す", function()
	local ctx = yazipane()
	ctx.run("preview")
	eq(table.concat(rt.mgr.ratio, ","), "0,3,0", "隠した比率")
	eq(pubs(ctx, "yazipane-preview")[1].value, true, "反対ペインへの通知")
	ctx.run("preview")
	eq(table.concat(rt.mgr.ratio, ","), "0,3,2", "戻した比率")
	eq(pubs(ctx, "yazipane-preview")[2].value, false, "反対ペインへの通知")
end)

test("Alt+P: 反対ペインから届いた切り替えは、1 画面のときは 2 画面に戻ったときの比率にだけ反映する", function()
	local ctx = load { env = { YAZIPANE_NATIVE_RATIO = "1,3,4", YAZIPANE_PEER = "2" } }
	ctx.run("layout-single")
	ctx.remote["yazipane-preview"](true)
	eq(table.concat(rt.mgr.ratio, ","), "1,3,4", "1 画面の表示は変えない")
	ctx.run("layout-dual")
	eq(table.concat(rt.mgr.ratio, ","), "0,3,0", "2 画面に戻ったらプレビュー列は隠れている")
end)

test("Alt+L: 1 画面用 / 2 画面用の列を切り替える", function()
	local ctx = load { env = { YAZIPANE_NATIVE_RATIO = "1,3,4", YAZIPANE_PEER = "2" } }
	ctx.run("layout-toggle")
	eq(table.concat(rt.mgr.ratio, ","), "1,3,4", "1 画面用")
	ctx.run("layout-toggle")
	eq(table.concat(rt.mgr.ratio, ","), "0,3,2", "2 画面用")
end)

-- ---- 起動時 ----

test("起動時: yazipane.exe からの警告を左ペインでだけ通知する", function()
	local env = { YAZIPANE_PEER = "2", YAZIPANE_SIDE = "left", YAZIPANE_WARNINGS = "yazi.toml を読めません" }
	local ctx = load { env = env }
	eq(ctx.notes[1], "warn:yazi.toml を読めません")
	env.YAZIPANE_SIDE = "right"
	ctx = load { env = env }
	eq(#ctx.notes, 0, "右ペインでは通知しない")
end)

test("起動時: 反対ペインに今のフォルダを知らせ、問い合わせる", function()
	local ctx = yazipane()
	eq(pubs(ctx, "yazipane-cwd")[1].value, "C:\\work", "今のフォルダ")
	eq(#pubs(ctx, "yazipane-hello"), 1, "問い合わせ")
end)
T.finish()
