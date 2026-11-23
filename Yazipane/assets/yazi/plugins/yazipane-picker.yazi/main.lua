-- 候補の描画とキー入力を分け、yazi の既定の一覧にある左側の固定余白を避ける。
local show_candidates = ya.sync(function(state, cands)
	if not (Modal and Modal.children_add and Modal.children_remove) then
		return nil
	end
	local component = { _id = "yazipane-candidates", selected = 1 }
	function component:new(area) return setmetatable({ area = area }, { __index = self }) end
	function component:reflow() return { self } end
	function component:redraw()
		local a = self.area
		if a.w < 4 or a.h < 3 then return {} end
		local height = math.min(#cands, a.h - 2)
		local box = ui.Rect { x = a.x, y = a.y + a.h - height - 2, w = a.w, h = height + 2 }
		local inner = ui.Rect { x = box.x + 1, y = box.y + 1, w = box.w - 2, h = height }
		local lines = {}
		local first = math.max(1, math.min(self.selected - height + 1, #cands - height + 1))
		for i = 1, height do
			local index = first + i - 1
			lines[i] = (index == self.selected and "> " or "  ") .. cands[index].on .. "  " .. cands[index].desc
		end
		return { ui.Clear(box), ui.Border(ui.Edge.ALL):area(box), ui.Text(lines):area(inner) }
	end
	local id = Modal:children_add(component, 1000)
	state.candidate_component = component
	ui.render()
	return id
end)

local update_candidates = ya.sync(function(state, selected)
	if state.candidate_component then
		state.candidate_component.selected = selected
		ui.render()
	end
end)

local hide_candidates = ya.sync(function(state, id)
	Modal:children_remove(id)
	state.candidate_component = nil
	ui.render()
end)

local function choose(cands)
	local ok, id = pcall(show_candidates, cands)
	if not ok or not id then return ya.which { cands = cands } end
	local keys = { table.unpack(cands) }
	keys[#keys + 1] = { on = "<Up>" }
	keys[#keys + 1] = { on = "<Down>" }
	keys[#keys + 1] = { on = "<Enter>" }
	local current = 1
	local selected, result = pcall(function()
		while true do
			local key = ya.which { cands = keys, silent = true }
			if not key then return nil end
			if key <= #cands then return key end
			if key == #cands + 3 then return current end
			if key == #cands + 1 then
				current = math.max(1, current - 1)
			elseif key == #cands + 2 then
				current = math.min(#cands, current + 1)
			end
			update_candidates(current)
		end
	end)
	pcall(hide_candidates, id)
	if not selected then error(result) end
	return result
end


return { choose = choose }
