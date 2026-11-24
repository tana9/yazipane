-- 名前付きの組の保存 / 復元 / 削除。
local function run(deps)
	local require_exe, choose_candidates, run_exe = deps.require_exe, deps.choose, deps.run_exe
	local notify, failure, peer_dest = deps.notify, deps.failure, deps.peer_dest
	local get_cwd, send_cd, SIDE = deps.get_cwd, deps.send_cd, deps.side
	if not require_exe() then return end
	local mode = choose_candidates({
		{ on = "s", desc = "今の左右のフォルダを保存" },
		{ on = "o", desc = "保存した組を開く" },
		{ on = "d", desc = "保存した組を削除" },
	}, "フォルダの組")
	if not mode then return end
	local code, out, err = run_exe({ "--pairs", "list" })
	if code ~= 0 then return notify("保存した組を読めません: " .. failure(code, out, err), "error") end
	local pairs = {}
	for line in out:gmatch("[^\r\n]+") do
		local name, left, right = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
		if name then pairs[#pairs + 1] = { name = name, left = left, right = right } end
	end
	if mode == 1 then
		local peer = peer_dest(true)
		if not peer then return end
		local current = get_cwd()
		local left, right = current, peer
		if SIDE == "right" then left, right = peer, current end
		if SIDE ~= "left" and SIDE ~= "right" then return notify("ペインの位置が分かりません", "error") end
		local name, event = ya.input { title = "フォルダの組の名前", pos = { "center", w = 50 } }
		if event ~= 1 or not name or name == "" then return end
		for _, p in ipairs(pairs) do
			if p.name == name and not ya.confirm { title = "上書き", body = "同じ名前の組を上書きしますか？", pos = { "center", w = 50, h = 6 } } then return end
		end
		local saved, output, problem = run_exe({ "--pairs", "save", name, left, right })
		if saved ~= 0 then return notify("保存できません: " .. failure(saved, output, problem), "error") end
		return notify("フォルダの組を保存しました: " .. name)
	end
	if #pairs == 0 then return notify("保存されたフォルダの組はありません", "warn") end
	local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	local cands = {}
	for i, p in ipairs(pairs) do
		if i > #chars then break end
		cands[i] = { on = chars:sub(i, i), desc = p.name .. "  " .. p.left .. " │ " .. p.right }
	end
	local i = choose_candidates(cands, mode == 3 and "削除する組" or "開く組")
	if not i then return end
	local pair = pairs[i]
	if mode == 3 then
		if not ya.confirm { title = "削除", body = pair.name .. " を削除しますか？", pos = { "center", w = 50, h = 6 } } then return end
		local deleted, output, problem = run_exe({ "--pairs", "delete", pair.name })
		if deleted ~= 0 then return notify("削除できません: " .. failure(deleted, output, problem), "error") end
		return notify("フォルダの組を削除しました: " .. pair.name)
	end
	if not peer_dest(true) then return end
	local left = fs.cha(Url(pair.left), true)
	local right = fs.cha(Url(pair.right), true)
	if not left or not left.is_dir or not right or not right.is_dir then
		return notify("保存されたフォルダが見つかりません", "error")
	end
	local current, peer = pair.left, pair.right
	if SIDE == "right" then current, peer = pair.right, pair.left end
	if SIDE ~= "left" and SIDE ~= "right" then return notify("ペインの位置が分かりません", "error") end
	send_cd(peer)
	ya.emit("cd", { current, raw = true })
end


return { run = run }
