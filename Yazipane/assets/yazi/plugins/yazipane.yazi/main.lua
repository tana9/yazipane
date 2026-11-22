--- yazipane: 左右 2 つの yazi を DDS で連携させるプラグイン
---
--- 各 yazi は環境変数 YAZIPANE_PEER に相手のクライアント ID を受け取り、
--- 自分のカレントディレクトリを相手に通知し続ける。
--- Windows との連携（右クリックメニュー、クリップボード、コピー / 移動、ドライブ、エクスプローラー）は
--- yazipane.exe のサブコマンドに任せ、結果を標準出力と終了コードで受け取る。
---
--- 節の並び:
---   1. 環境と共通の関数
---   2. yazi の状態の読み書き（sync context）
---   3. cd のたびの処理（反対ペインへの通知、前回のフォルダの記録、空き容量）
---   4. 列の表示（1 画面 / 2 画面、プレビュー列）
---   5. 反対ペインとの連携
---   6. Windows との連携
---   7. キーの一覧
---   8. setup / entry

-- ==== 1. 環境と共通の関数 ====

local PEER = tonumber(os.getenv("YAZIPANE_PEER") or "")
local EXE = os.getenv("YAZIPANE_EXE")
local HAS_EXE = EXE ~= nil and EXE ~= ""
local SIDE = os.getenv("YAZIPANE_SIDE")
local STATE_DIR = os.getenv("YAZIPANE_STATE_DIR")

-- セッションとペインごとに別ファイルへ書き、他のプロセスとの競合を避ける。
local DEBUG = os.getenv("YAZIPANE_DEBUG") == "1"
local LOG_DIR = os.getenv("YAZIPANE_LOG_DIR")
local function dbg(msg)
	if not (DEBUG and LOG_DIR and SIDE) then
		return
	end
	local f = io.open(LOG_DIR .. "\\plugin-" .. SIDE .. ".log", "a")
	if f then
		f:write(tostring(os.date("%H:%M:%S ")), tostring(SIDE), " ", msg, "\n")
		f:close()
	end
end

local function notify(msg, level, timeout)
	ya.notify { title = "yazipane", content = msg, timeout = timeout or 3, level = level or "info" }
end

--- yazipane.exe が使えるか。使えなければ通知して false。
local function require_exe()
	if not HAS_EXE then
		notify("YAZIPANE_EXE が設定されていません", "error")
	end
	return HAS_EXE
end

--- yazipane.exe を呼び、終了コード・標準出力（末尾の空白を除く）・標準エラー出力を返す。
--- 起動できなければ nil とエラーの説明を返す。
local function run_exe(args)
	local out, err = Command(EXE):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then
		return nil, tostring(err)
	end
	return out.status.code, out.stdout:gsub("%s+$", ""), out.stderr
end

--- run_exe が失敗したときの理由（起動できなかった説明か、標準エラー出力）
local function failure(code, out, err)
	return tostring(code and err or out)
end

--- args の後ろに paths を足した新しい表
local function with_paths(args, paths)
	local list = { table.unpack(args) }
	for _, p in ipairs(paths) do
		list[#list + 1] = p
	end
	return list
end

--- yazipane.exe --transfer / --paste が返す件数（"できた件数 スキップした件数 失敗した件数"）を読む
local function parse_counts(s)
	local done, skipped, errors = (s or ""):match("(%d+) (%d+) (%d+)$")
	return tonumber(done) or 0, tonumber(skipped) or 0, tonumber(errors) or 0
end

--- コピー / 移動 / 貼り付けの結果を通知する。
--- 終了コード 0 = 実行した（件数あり）/ 4 = 途中で中止 / 5 = 対象が無い / それ以外 = 失敗。what は「反対ペインへコピー」など。
--- 実行できたら true。
local function notify_result(what, code, out, err)
	if code == 0 or code == 4 then
		local done, skipped, errors = parse_counts(out)
		local notes = {}
		if skipped > 0 then
			notes[#notes + 1] = string.format("%d 件はスキップ", skipped)
		end
		if errors > 0 then
			notes[#notes + 1] = string.format("%d 件は失敗", errors)
		end
		local note = #notes > 0 and ("（" .. table.concat(notes, "、") .. "）") or ""
		if code == 4 then
			notify(string.format("%sを中止しました（%d 件は完了）%s", what, done, note), "warn")
		elseif done == 0 then
			notify(string.format("%sしたものはありません%s", what, note), errors > 0 and "error" or "warn")
		else
			notify(string.format("%d 件を%sしました%s", done, what, note), errors > 0 and "warn" or "info")
		end
		return code == 0
	elseif code == 5 then
		notify(err, "warn")
	else
		notify(what .. "できません: " .. failure(code, out, err), "error")
	end
	return false
end

local function base_name(path)
	return path:match("[^\\/]+$") or path
end

local function drive_root(path)
	return path:match("^(%a:\\)")
end

-- 反対ペインへ送る（sync context 用）。
-- 相手がまだ接続していない / 既に終了していることがあるので、送れなくてもエラーにしない。
local function pub(kind, value)
	if PEER then
		pcall(ps.pub_to, PEER, kind, value)
	end
end

-- ==== 2. yazi の状態の読み書き（sync context） ====

local get_cwd = ya.sync(function() return tostring(cx.active.current.cwd) end)

-- カーソル位置の項目のパス（無ければ nil）
local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	return h and tostring(h.url) or nil
end)

-- カーソル位置がディレクトリならそのパスを返す
local get_hovered_dir = ya.sync(function()
	local h = cx.active.current.hovered
	if h and h.cha.is_dir then
		return tostring(h.url)
	end
end)

-- yazi と同じ考え方の対象（選択があれば選択、無ければカーソル位置）
local get_targets = ya.sync(function()
	local tab = cx.active
	local paths = {}
	for _, url in pairs(tab.selected) do
		paths[#paths + 1] = tostring(url)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url)
	end
	return paths
end)

--- 右クリックメニューの対象を決める（エクスプローラーと同じ考え方）。
--- カーソル位置が選択に含まれていれば選択全体、含まれていなければ選択を解除してカーソル位置だけ。
--- Windows のメニューは 1 つのフォルダの中身にしか出せないので、カーソル位置と同じフォルダのものだけに絞る。
--- 戻り値: { paths = 対象のパス一覧, skipped = 別のフォルダにあるため外した件数 }
local get_menu_targets = ya.sync(function()
	local tab = cx.active
	local hovered = tab.current.hovered
	local selected = {}
	for _, url in pairs(tab.selected) do
		selected[#selected + 1] = url
	end
	if not hovered then
		local paths = {}
		for _, u in ipairs(selected) do
			paths[#paths + 1] = tostring(u)
		end
		return { paths = paths, skipped = 0 }
	end

	local h = tostring(hovered.url)
	local in_selection = false
	for _, u in ipairs(selected) do
		if tostring(u) == h then
			in_selection = true
			break
		end
	end
	if not in_selection then
		if #selected > 0 then
			ya.emit("escape", { select = true })
		end
		return { paths = { h }, skipped = 0 }
	end

	local parent = tostring(hovered.url.parent)
	local paths, skipped = {}, 0
	for _, u in ipairs(selected) do
		if tostring(u.parent) == parent then
			paths[#paths + 1] = tostring(u)
		else
			skipped = skipped + 1
		end
	end
	return { paths = paths, skipped = skipped }
end)

-- 今のフォルダの項目（表示中のもの）の名前・URL・ディレクトリか・更新日時
local get_current_files = ya.sync(function()
	local list = {}
	for _, f in ipairs(cx.active.current.files) do
		list[#list + 1] = { name = f.name, url = tostring(f.url), is_dir = f.cha.is_dir, mtime = f.cha.mtime }
	end
	return list
end)

local clear_selection = ya.sync(function() ya.emit("escape", { select = true }) end)

-- urls だけを選択した状態にする（toggle は URL を取らないので、カーソルを移しながら選択し、最後にカーソルを戻す）
local select_only = ya.sync(function(_, urls)
	local h = cx.active.current.hovered
	local back = h and tostring(h.url)
	ya.emit("escape", { select = true })
	for _, u in ipairs(urls) do
		ya.emit("reveal", { u })
		ya.emit("toggle", { state = "on" })
	end
	if back then
		ya.emit("reveal", { back })
	end
end)

-- ドラッグ中は yazi から drag イベントが続けて届くので、1 回だけ開始する
local begin_drag = ya.sync(function(state)
	if state.dragging then
		return false
	end
	state.dragging = true
	return true
end)
local end_drag = ya.sync(function(state) state.dragging = false end)

-- 反対ペインのカレントディレクトリ（最後に通知されたもの / 問い合わせへの返事）
local get_fresh_peer_cwd = ya.sync(function(state) return state.peer_cwd_fresh end)

-- 反対ペインに今のディレクトリを問い合わせる（返事は yazipane-cwd で届く）
local request_peer_cwd = ya.sync(function(state)
	state.peer_cwd_fresh = nil
	pub("yazipane-hello", true)
end)

local send_push = ya.sync(function() pub("yazipane-cd", tostring(cx.active.current.cwd)) end)
local send_cd = ya.sync(function(_, url) pub("yazipane-cd", url) end)

-- 片方だけ終了すると半分の画面が残るので、反対ペインにも終了を伝えてから自分も終了する
local quit_both = ya.sync(function()
	pub("yazipane-quit", true)
	ya.emit("quit", {})
end)

-- ==== 3. cd のたびの処理 ====

local plugin_state -- setup で受け取るプラグインの状態（sync context から使う）

-- sync context 用
local function publish_cwd()
	if cx and cx.active then
		pub("yazipane-cwd", tostring(cx.active.current.cwd))
	end
end

-- 次回起動時に同じフォルダを開けるよう、今のフォルダを記録する（ウィンドウを閉じて終了しても残るよう、移動のたびに書く）
local function save_cwd()
	if not (STATE_DIR and SIDE and cx and cx.active) then
		return
	end
	local f = io.open(STATE_DIR .. "\\last-" .. SIDE .. ".txt", "w")
	if f then
		f:write(tostring(cx.active.current.cwd))
		f:close()
	end
end

-- ステータスバーのドライブの空き容量は yazipane.exe --free で取る。
-- cd のたびに起動しないよう、ドライブごとに FREE_TTL 秒だけ覚えておく。
local FREE_TTL = 10

-- sync context 用: 今のドライブの空き容量が古ければ、取り直しを依頼する（plugin yazipane free）。
-- 取り直しが終わるまでの間に cd が続いても何度も依頼しないよう、依頼した時刻も覚えておく。
local function request_free()
	if not (plugin_state and HAS_EXE and cx and cx.active) then
		return
	end
	local root = drive_root(tostring(cx.active.current.cwd))
	if not root then
		return
	end
	local now = os.time()
	local cached = plugin_state.free[root]
	local requested = plugin_state.free_requested[root]
	if (cached and now - cached.time < FREE_TTL) or (requested and now - requested < FREE_TTL) then
		return
	end
	plugin_state.free_requested[root] = now
	ya.emit("plugin", { "yazipane", "free" })
end

local set_free = ya.sync(function(state, root, text)
	state.free[root] = { text = text, time = os.time() }
	ui.render()
end)

local function on_cd()
	publish_cwd()
	pcall(save_cwd)
	pcall(request_free)
end

-- ==== 4. 列の表示 ====

-- 1 画面のときに使う、普段の yazi の列の比率（yazipane.exe が普段の yazi.toml から読み取って渡す）
local NATIVE = {}
for n in (os.getenv("YAZIPANE_NATIVE_RATIO") or "1,4,3"):gmatch("%d+") do
	NATIVE[#NATIVE + 1] = tonumber(n)
end
if #NATIVE ~= 3 then
	NATIVE = { 1, 4, 3 }
end

--- 今の表示のプレビュー列（右の列）を表示/非表示にする（sync context）。hide が nil なら反転する。
local function apply_preview(state, hide)
	local r = rt.mgr.ratio
	local single = state.layout == "single"
	if hide == nil then
		hide = r[3] ~= 0
	end
	if hide then
		if r[3] ~= 0 and not single then
			state.preview_ratio = r[3]
		end
		rt.mgr.ratio = { r[1], r[2], 0 }
	else
		-- 1 画面のときは普段の比率、2 画面のときは隠す前の比率に戻す
		rt.mgr.ratio = { r[1], r[2], single and NATIVE[3] or (state.preview_ratio or 2) }
	end
	ya.emit("app:resize", {})
	return hide
end

--- 反対ペインから届いた切り替え。
--- 1 画面のときは今の表示を変えず、2 画面に戻ったときの比率だけを合わせる。
local function apply_remote_preview(state, hide)
	if state.layout ~= "single" then
		return apply_preview(state, hide)
	end
	local d = state.dual_ratio
	if not d then
		return
	end
	if hide then
		if d[3] ~= 0 then
			state.preview_ratio = d[3]
		end
		d[3] = 0
	else
		d[3] = state.preview_ratio or 2
	end
end

--- 1 画面（WezTerm でペインをズーム）なら普段の 3 列表示に、2 画面なら 2 画面用の表示に戻す
local set_layout = ya.sync(function(state, mode)
	local r = rt.mgr.ratio
	if mode == "toggle" then
		mode = state.layout == "single" and "dual" or "single"
	end
	if mode == "single" then
		if state.layout ~= "single" then
			state.dual_ratio = { r[1], r[2], r[3] }
		end
		state.layout = "single"
		rt.mgr.ratio = { NATIVE[1], NATIVE[2], NATIVE[3] }
	elseif mode == "dual" then
		if state.layout == "single" and state.dual_ratio then
			rt.mgr.ratio = state.dual_ratio
		end
		state.layout = "dual"
	else
		return
	end
	local a = rt.mgr.ratio
	dbg(string.format("layout %s -> ratio %s,%s,%s", mode, a[1], a[2], a[3]))
	ya.emit("app:resize", {})
end)

-- 自分のペインを切り替え、2 画面のときは反対ペインも同じ状態にそろえる
-- （1 画面のときは見えているペインだけの話なので、反対ペインには伝えない）
local toggle_preview = ya.sync(function(state)
	local hide = apply_preview(state, nil)
	if state.layout ~= "single" then
		pub("yazipane-preview", hide)
	end
end)

-- ==== 5. 反対ペインとの連携 ====

-- 相手のカレントディレクトリを取得する。
-- yazi のタブ切り替えなどで通知が漏れても正しい場所を使えるよう、毎回問い合わせて返事を待つ。
-- 返事が来なければ操作を中止する（最後の通知は古い可能性がある）。
local function peer_cwd()
	request_peer_cwd()
	for _ = 1, 20 do
		ya.sleep(0.025)
		local fresh = get_fresh_peer_cwd()
		if fresh then
			return fresh
		end
	end
	return nil
end

--- 反対ペインの場所。分からなければ通知して nil。
--- allow_same でなければ、こちらと同じ場所のときも通知して nil。
local function peer_dest(allow_same)
	local dest = peer_cwd()
	if not dest then
		notify("反対ペインの場所が分かりません", "error")
		return nil
	end
	if not allow_same and dest == get_cwd() then
		notify("両方のペインが同じディレクトリです", "warn")
		return nil
	end
	return dest
end

-- こちらを反対ペインと同じフォルダにする（Alt+O）
local function pull()
	local dest = peer_dest(true)
	if dest then
		ya.emit("cd", { dest, raw = true })
	end
end

-- 左右のディレクトリを入れ替える（Alt+S）
local function swap()
	local dest = peer_dest(true)
	if not dest or dest == get_cwd() then
		return
	end
	send_push()
	ya.emit("cd", { dest, raw = true })
end

-- カーソル位置のディレクトリを反対ペインで開く（Alt+I）
local function open_in_peer()
	local dir = get_hovered_dir()
	if not dir then
		return notify("ディレクトリにカーソルを合わせてください", "warn")
	end
	send_cd(dir)
end

-- 左右の順序を保ち、同じフォルダで別のウィンドウを開く。
local function new_window()
	if not require_exe() then
		return
	end
	local peer = peer_dest(true)
	if not peer then
		return
	end
	if SIDE ~= "left" and SIDE ~= "right" then
		return notify("ペインの位置が分かりません", "error")
	end
	local current = get_cwd()
	local left, right = current, peer
	if SIDE == "right" then
		left, right = peer, current
	end
	local code, out, err = run_exe({ "--new-window", left, right })
	if code ~= 0 then
		notify("新しいウィンドウを起動できません: " .. failure(code, out, err), "error")
	end
end

--- 反対ペインへコピー / 移動する（F5 / F6）。
--- エクスプローラーと同じファイル操作（yazipane.exe --transfer）で行うので、同名のファイルがあれば
--- 置き換え / スキップを選ぶダイアログが出る。y でヤンクした内容には触れない。
--- confirm が true なら、実行前に件数とコピー先を確認する。targets を省略すると選択（無ければカーソル位置）。
local function transfer(action, confirm, targets)
	if not require_exe() then
		return
	end
	local dest = peer_dest(false)
	if not dest then
		return
	end
	targets = targets or get_targets()
	if #targets == 0 then
		return
	end

	local verb = action == "move" and "移動" or "コピー"
	if confirm then
		local what = #targets == 1 and base_name(targets[1]) or string.format("%d 件", #targets)
		local yes = ya.confirm {
			pos = { "center", w = 64, h = 10 },
			title = "反対ペインへ" .. verb,
			body = ui.Text(string.format("%s を\n%s\nへ%sします。", what, dest, verb)):wrap(ui.Wrap.YES),
		}
		if not yes then
			return
		end
	end

	local code, out, err = run_exe(with_paths({ "--transfer", action, dest }, targets))
	if notify_result("反対ペインへ" .. verb, code, out, err) then
		clear_selection()
	end
	if code == 0 or code == 4 then
		ya.emit("plugin", { "yazipane", "free" })
	end
end

--- 反対ペインと比べて、こちらにしか無いもの・こちらの方が新しいファイルを選択する（Alt+C）。
--- そのまま F5 を押せば、反対ペインに足りないものをコピーできる。サブフォルダの中までは比べない。
local function compare()
	local dest = peer_dest(false)
	if not dest then
		return
	end
	local theirs, err = fs.read_dir(Url(dest), {})
	if not theirs then
		return notify("反対ペインのフォルダを読めません: " .. tostring(err), "error")
	end
	-- Windows のファイル名は大文字と小文字を区別しない
	local peer = {}
	for _, f in ipairs(theirs) do
		peer[f.name:lower()] = f
	end

	local picks, only, newer = {}, 0, 0
	for _, f in ipairs(get_current_files()) do
		local p = peer[f.name:lower()]
		if not p then
			picks[#picks + 1] = f.url
			only = only + 1
		elseif not f.is_dir and not p.cha.is_dir and (f.mtime or 0) > (p.cha.mtime or 0) then
			picks[#picks + 1] = f.url
			newer = newer + 1
		end
	end
	select_only(picks)
	if #picks == 0 then
		notify("反対ペインと同じです（こちらにしか無いもの・こちらの方が新しいものはありません）")
	else
		notify(string.format("こちらにしか無い %d 件、こちらの方が新しい %d 件を選択しました（F5 で反対ペインへコピー）", only, newer))
	end
end

-- ==== 6. Windows との連携 ====

-- Windows の右クリックメニュー（右クリック / Shift+F10）。yazipane 独自の項目が選ばれたら、その動作名が返る。
local function context_menu()
	if not require_exe() then
		return
	end
	local result = get_menu_targets()
	local targets, skipped = result.paths, result.skipped
	if #targets == 0 then
		return
	end
	if skipped > 0 then
		notify(string.format("別のフォルダにある %d 件は右クリックメニューの対象外です", skipped), "warn", 5)
	end

	local code, out, err = run_exe(with_paths({ "--context-menu" }, targets))
	if not code then
		return notify("メニューを表示できません: " .. out, "error")
	end
	if code ~= 0 then
		return notify("メニューの表示に失敗しました: " .. err, "error")
	end

	if out == "copy" or out == "move" then
		-- メニューで選んだ時点で意図ははっきりしているので、確認は出さない
		transfer(out, false, targets)
	elseif out == "copypath" then
		ya.emit("copy", { "path" })
	elseif out == "rename" then
		-- エクスプローラーの外では「名前の変更」が動かないので yazi の名前変更を使う（既定の r と同じ）
		ya.emit("rename", { cursor = "before_ext" })
	end
end

-- 選択（無ければカーソル位置）のファイルをクリップボードにコピーする（Ctrl+C。ほかのアプリで Ctrl+V）
local function clipboard(move)
	if not require_exe() then
		return
	end
	local targets = get_targets()
	if #targets == 0 then
		return
	end
	local code, out, err = run_exe(with_paths({ move and "--clipboard-cut" or "--clipboard" }, targets))
	if code ~= 0 then
		return notify("クリップボードに" .. (move and "切り取り" or "コピー") .. "できません: " .. failure(code, out, err), "error")
	end
	local n = tonumber(out) or #targets
	notify(string.format("%d 件をクリップボードに%sしました（ほかのアプリで Ctrl+V）", n, move and "切り取り" or "コピー"))
end

--- エクスプローラーなどでコピー / 切り取りしたファイルを、今のフォルダへ貼り付ける（Ctrl+V）
local function paste_clipboard()
	if not require_exe() then
		return
	end
	local code, out, err = run_exe({ "--paste", get_cwd() })
	-- 出力は "copy|move できた件数 スキップした件数 失敗した件数"
	local kind = (out or ""):match("^(%a+) ")
	notify_result(kind == "move" and "移動" or "貼り付け", code, out, err)
	if code == 0 or code == 4 then
		ya.emit("plugin", { "yazipane", "free" })
	end
end

-- yazi でドラッグを始めたら、Windows 標準のドラッグを開始してほかのアプリへファイルを渡す
local function drag()
	if not HAS_EXE or not begin_drag() then
		return
	end
	-- 途中でエラーになってもドラッグ中のままにならないよう、必ず end_drag する
	local ok, err = pcall(function()
		local targets = get_menu_targets().paths
		if #targets == 0 then
			return
		end
		local code, _, stderr = run_exe(with_paths({ "--drag" }, targets))
		if code == 1 then
			notify("ドラッグできません: " .. stderr, "error")
		end
	end)
	end_drag()
	if not ok then
		dbg("drag failed: " .. tostring(err))
	end
end

--- ドライブの一覧から選んで移動する（Alt+D）。キーはドライブ名の英字。
local function drives()
	if not require_exe() then
		return
	end
	local code, out, err = run_exe({ "--drives" })
	if code ~= 0 then
		return notify("ドライブの一覧を取得できません: " .. failure(code, out, err), "error")
	end
	local roots, cands = {}, {}
	for line in out:gmatch("[^\r\n]+") do
		local root, desc = line:match("^(%a:\\)\t(.*)$")
		if root then
			roots[#roots + 1] = root
			cands[#cands + 1] = { on = root:sub(1, 1):lower(), desc = root .. "  " .. desc }
		end
	end
	if #cands == 0 then
		return notify("ドライブが見つかりません", "warn")
	end
	local i = ya.which { cands = cands }
	if i then
		ya.emit("cd", { roots[i], raw = true })
	end
end

--- 今のフォルダをエクスプローラーで開く（Alt+E）。カーソル位置の項目があれば選択した状態にする。
--- yazi の既定の opener の reveal（Windows では explorer /select,%s1）と同じコマンドを、yazi の shell で実行する。
local function open_explorer()
	if get_hovered() then
		ya.emit("shell", { "explorer /select,%h", orphan = true })
	else
		-- 空のフォルダなど、カーソル位置の項目が無いときはフォルダそのものを開く（shell は今のフォルダで実行される）
		ya.emit("shell", { "explorer .", orphan = true })
	end
end

--- 今のドライブの空き容量を取り直してステータスバーに出す（cd のときに request_free から呼ばれる）
local function refresh_free()
	local root = drive_root(get_cwd())
	if not root or not HAS_EXE then
		return
	end
	local code, out = run_exe({ "--free", root })
	if code == 0 and out ~= "" then
		set_free(root, out)
	end
end

-- ==== 7. キーの一覧 ====

-- yazipane 独自のキーの一覧（yazi のヘルプ F1 には WezTerm 側のキーが出ないので、まとめて見られるようにする）
local HELP = {
	"── ペイン（WezTerm）──",
	"Ctrl+Tab / Ctrl+Shift+Tab   次 / 前のペインへ",
	"Ctrl+Shift+Z                1 画面 / 2 画面の切り替え",
	"Ctrl+Shift+Alt+← / →        ペインの境目を動かす",
	"Ctrl+Shift+E                左右を同じ幅に戻す",
	"",
	"── 2 画面の連携 ──",
	"F5 / F6           反対ペインへコピー / 移動",
	"=                 反対ペインをこちらと同じフォルダに",
	"Alt+O             こちらを反対ペインと同じフォルダに",
	"Alt+S             左右のフォルダを入れ替え",
	"Alt+I             カーソル位置のフォルダを反対ペインで開く",
	"Alt+N             同じ左右のフォルダで新しいウィンドウを開く",
	"q                 両方のペインを終了",
	"",
	"── Windows との連携 ──",
	"Ctrl+C / Ctrl+V   クリップボードへコピー / から貼り付け",
	"Alt+X             クリップボードへ切り取り",
	"右クリック / Shift+F10   右クリックメニュー",
	"Alt+D             ドライブを選んで移動",
	"Alt+E             エクスプローラーで開く",
	"",
	"── 表示 ──",
	"Alt+L             列の表示（2 画面用 / yazi 本来の 3 列）",
	"Alt+P             プレビュー列の表示 / 非表示",
	"Alt+C             反対ペインと比べ、こちらにしか無い / 新しいものを選択",
	"Alt+H             このキー一覧",
}

local function show_help()
	ya.confirm {
		pos = { "center", w = 72, h = #HELP + 4 },
		title = "yazipane のキー（yazi のキーは F1）",
		body = ui.Text(table.concat(HELP, "\n")),
	}
end

-- ==== 8. setup / entry ====

local M = {}

function M:setup()
	local state = self
	plugin_state = state
	state.free = {}
	state.free_requested = {}

	-- ステータスバーの右側に、今のドライブの空き容量を出す
	pcall(function()
		Status:children_add(function()
			local root = cx.active and drive_root(tostring(cx.active.current.cwd))
			local cached = root and state.free[root]
			return cached and ui.Line(" " .. cached.text .. " ") or ""
		end, 1500, Status.RIGHT)
	end)

	if not PEER then
		return
	end

	ps.sub_remote("yazipane-cwd", function(cwd)
		state.peer_cwd = cwd
		state.peer_cwd_fresh = cwd
	end)
	ps.sub_remote("yazipane-hello", function() publish_cwd() end)
	ps.sub_remote("yazipane-cd", function(url) ya.emit("cd", { url, raw = true }) end)
	ps.sub_remote("yazipane-preview", function(hide) apply_remote_preview(state, hide) end)
	ps.sub_remote("yazipane-quit", function() ya.emit("quit", {}) end)

	ps.sub("cd", on_cd)
	pcall(ps.sub, "tab", on_cd)
	pcall(request_free)

	-- 起動直後は相手がまだ接続していないことがある（pub がエラーを無視する）
	pcall(publish_cwd)
	pub("yazipane-hello", true)

	-- yazipane.exe からの警告（普段の yazi.toml が読めない等）を左ペインで 1 回だけ表示する
	local warnings = os.getenv("YAZIPANE_WARNINGS")
	if warnings and warnings ~= "" and SIDE == "left" then
		pcall(notify, warnings, "warn", 10)
	end
end

-- keymap.toml の "plugin yazipane <操作>" の <操作> → 処理（プラグインへの引数は 1 語にする）。
-- 反対ペインが無くても使える操作
local ACTIONS = {
	menu = context_menu,
	clipboard = function() clipboard(false) end,
	["clipboard-cut"] = function() clipboard(true) end,
	paste = paste_clipboard,
	drag = drag,
	drives = drives,
	explorer = open_explorer,
	free = refresh_free,
	help = show_help,
	quit = quit_both,
	preview = toggle_preview,
}

-- 反対ペイン（yazipane から起動された相手の yazi）が必要な操作
local PEER_ACTIONS = {
	push = send_push,
	pull = pull,
	swap = swap,
	["open-peer"] = open_in_peer,
	["new-window"] = new_window,
	compare = compare,
	copy = function() transfer("copy", true) end,
	move = function() transfer("move", true) end,
	-- 確認なし（確認が要らなければ keymap.toml でこちらに割り当てる。スモークテストでも使う）
	["copy-now"] = function() transfer("copy", false) end,
	["move-now"] = function() transfer("move", false) end,
}

function M:entry(job)
	local action = job.args[1]
	if ACTIONS[action] then
		return ACTIONS[action]()
	end
	if action and action:sub(1, 7) == "layout-" then
		-- layout-single / layout-dual / layout-toggle
		return set_layout(action:sub(8))
	end
	if not PEER then
		return notify("yazipane から起動された yazi ではありません", "warn")
	end
	if PEER_ACTIONS[action] then
		return PEER_ACTIONS[action]()
	end
	notify("不明な操作です: " .. tostring(action), "error")
end

return M
