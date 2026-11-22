require("yazipane"):setup()

-- y / x でヤンクした内容を反対ペインにも引き継ぐ（左で y → 右で p ができる）。
-- yazi 組み込みの session プラグインの機能。普段の init.lua でも設定済みの場合に二重登録で止まらないよう pcall で囲む。
pcall(function() require("session"):setup { sync_yanked = true } end)

-- ---- マウス（現在のフォルダの列だけを対象にする。親フォルダ / プレビューの列は yazi の既定のまま） ----

-- 左ボタンを押した位置がファイルの行の上だったか（ドラッグをそこから始めたときだけ、ほかのアプリへのドラッグにする）
local yazipane_press_on_file = false

local yazipane_current_click = Current.click
function Current:click(event, up)
	-- yazi の内部フィールドに依存しているので、読めない版では yazi の既定の動作に任せる
	if not (self._area and self._folder and self._folder.window) then
		return yazipane_current_click(self, event, up)
	end
	local y = event.y - self._area.y + 1
	local file = self._folder.window[y]

	if event.is_left then
		yazipane_press_on_file = not up and file ~= nil
	end

	-- 右クリックで Windows の右クリックメニューを出す（既定ではカーソル移動 + 開く）
	if event.is_right then
		if not up and file then
			ya.emit("reveal", { file.url })
			ya.emit("plugin", { "yazipane", "menu" })
		end
		return
	end
	return yazipane_current_click(self, event, up)
end

-- ドラッグでほかのアプリへファイルを渡す（WezTerm は yazi 組み込みのドラッグに対応していないため、Windows 標準のドラッグを使う）
function Current:drag(event)
	if yazipane_press_on_file then
		ya.emit("plugin", { "yazipane", "drag" })
	end
end
