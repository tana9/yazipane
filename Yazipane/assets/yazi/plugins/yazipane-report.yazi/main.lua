-- 長い一覧を上下に動かして確認し、選択するかを尋ねる。
-- 色・枠・見出しは yazipane-picker と共通（枠と見出しは [pick]、操作の説明は [which]）。

local TITLE = "左右の違い"

local show = ya.sync(function(state, lines)
	if not (Modal and Modal.children_add and Modal.children_remove) then return nil end
	-- 描画は sync context なので、picker もここで読み込む
	local picker = require("yazipane-picker")
	local t = picker.theme()
	local component = { _id = "yazipane-report", offset = 0 }
	function component:new(area) return setmetatable({ area = area }, { __index = self }) end
	function component:reflow() return { self } end
	function component:redraw()
		local a = self.area
		if a.w < 4 or a.h < 4 then return {} end
		local height = math.min(#lines + 1, a.h - 2)
		local box = ui.Rect { x = a.x, y = a.y + a.h - height - 2, w = a.w, h = height + 2 }
		local inner = ui.Rect { x = box.x + 1, y = box.y + 1, w = box.w - 2, h = height }
		local offset = math.min(self.offset, math.max(0, #lines - height + 1))
		local text = { ui.Line("↑↓: 移動  S: こちらの新しい項目を選択  Esc: 閉じる"):style(t.separator_style) }
		for i = 1, height - 1 do
			local line = lines[offset + i]
			if line then text[#text + 1] = ui.Line(line):style(t.inactive) end
		end
		local elements = {
			ui.Clear(box),
			picker.rounded_border(box, t),
			ui.Text(text):area(inner),
		}
		elements[#elements + 1] = picker.title_on_border(box, TITLE, t.border)
		return elements
	end
	local id = Modal:children_add(component, 1000)
	state.report = component
	ui.render()
	return id
end)

local update = ya.sync(function(state, offset)
	if state.report then state.report.offset = offset ui.render() end
end)

local hide = ya.sync(function(state, id)
	Modal:children_remove(id)
	state.report = nil
	ui.render()
end)

local function view(lines)
	local ok, id = pcall(show, lines)
	if not ok or not id then
		return ya.confirm { title = TITLE, body = ui.Text(table.concat(lines, "\n")), pos = { "center", w = 70, h = 20 } }
	end
	local offset = 0
	local success, result = pcall(function()
		while true do
			local key = ya.which { silent = true, cands = {
				{ on = "<Up>" }, { on = "<Down>" }, { on = "<PageUp>" }, { on = "<PageDown>" },
				{ on = "s" }, { on = "<Enter>" },
			} }
			if not key or key == 6 then return false end
			if key == 5 then return true end
			local delta = ({ -1, 1, -8, 8 })[key]
			if delta then offset = math.max(0, math.min(#lines - 1, offset + delta)) update(offset) end
		end
	end)
	pcall(hide, id)
	if not success then error(result) end
	return result
end

return { view = view }
