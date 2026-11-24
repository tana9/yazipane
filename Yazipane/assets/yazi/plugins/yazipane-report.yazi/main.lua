-- 長い一覧を上下に動かして確認し、選択するかを尋ねる。
-- 色はテーマに合わせる（yazipane-picker と同じ。枠と見出しは [pick]、操作の説明は [which]）。
-- yazipane-picker にも同じ関数がある（ya.sync の中から別のプラグインの関数を呼ばないため）。変えるときは両方を合わせる。
local function theme()
	local plain = ui.Style()
	local function style(section, name)
		local ok, s = pcall(function() return th[section][name] end)
		return ok and s ~= nil and type(s) ~= "string" and s or plain
	end
	return {
		border = style("pick", "border"),
		inactive = style("pick", "inactive"),
		hint = style("which", "separator_style"),
	}
end

local TITLE = "左右の違い"

local show = ya.sync(function(state, lines)
	if not (Modal and Modal.children_add and Modal.children_remove) then return nil end
	local t = theme()
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
		local text = { ui.Line("↑↓: 移動  S: こちらの新しい項目を選択  Esc: 閉じる"):style(t.hint) }
		for i = 1, height - 1 do
			local line = lines[offset + i]
			if line then text[#text + 1] = ui.Line(line):style(t.inactive) end
		end
		-- 枠は yazi の選択の一覧と同じ角丸（ui.Border.ROUNDED はドキュメントにあるが型定義に無い）
		---@diagnostic disable-next-line: undefined-field
		local rounded = ui.Border.ROUNDED
		local elements = {
			ui.Clear(box),
			ui.Border(ui.Edge.ALL):type(rounded):style(t.border):area(box),
			ui.Text(text):area(inner),
		}
		-- 枠の上辺に見出しを重ねて描く（ui.Border には見出しを付ける API が無い）
		if box.w >= 6 then
			elements[#elements + 1] = ui.Text(" " .. TITLE .. " "):style(t.border)
				:area(ui.Rect { x = box.x + 2, y = box.y, w = box.w - 4, h = 1 })
		end
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
