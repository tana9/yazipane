-- Lua のテストの小さな枠組み（plugin_test.lua / wezterm_test.lua で共有する）。
--   local t = dofile(<このファイル>)("テストの名前")
--   t.test("…", function() t.eq(actual, expected, "何の値か") end)
--   t.finish()   -- 結果を表示し、失敗があれば終了コード 1 で終わる

return function(suite)
	local failures, count = {}, 0
	local t = {}

	function t.test(name, fn)
		count = count + 1
		local ok, err = pcall(fn)
		if not ok then
			failures[#failures + 1] = name .. "\n    " .. tostring(err)
		end
	end

	function t.eq(actual, expected, what)
		if actual ~= expected then
			error(string.format("%s: %q を期待したが %q だった", what or "値", tostring(expected), tostring(actual)), 2)
		end
	end

	function t.finish()
		if #failures > 0 then
			for _, f in ipairs(failures) do
				print("[FAIL] " .. f)
			end
			print(string.format("%s: 失敗 %d / %d", suite, #failures, count))
			os.exit(1)
		end
		print(string.format("%s: 成功 %d / %d", suite, count, count))
	end

	return t
end
