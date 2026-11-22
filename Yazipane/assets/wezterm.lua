-- yazipane 専用の WezTerm 設定（yazipane.exe が書き出す。直接編集しても次回起動時に上書きされる）
local wezterm = require 'wezterm'
local mux = wezterm.mux
local act = wezterm.action

local config = wezterm.config_builder()

local yazi = os.getenv 'YAZIPANE_YAZI' or 'yazi'
local left_dir = os.getenv 'YAZIPANE_LEFT_DIR' or wezterm.home_dir
local right_dir = os.getenv 'YAZIPANE_RIGHT_DIR' or left_dir
local left_id = os.getenv 'YAZIPANE_LEFT_ID' or '1'
local right_id = os.getenv 'YAZIPANE_RIGHT_ID' or '2'

-- Windows の WezTerm は起動時にレジストリのユーザー環境変数で自身の環境を上書きするため、
-- yazipane.exe からは YAZIPANE_CONFIG_HOME という別名で受け取り、ここで YAZI_CONFIG_HOME に詰め替える
local function pane_env(peer, side)
  return {
    YAZI_CONFIG_HOME = os.getenv 'YAZIPANE_CONFIG_HOME',
    YAZIPANE_USER_CONFIG_HOME = os.getenv 'YAZIPANE_USER_CONFIG_HOME',
    YAZIPANE_EXE = os.getenv 'YAZIPANE_EXE',
    YAZIPANE_NATIVE_RATIO = os.getenv 'YAZIPANE_NATIVE_RATIO',
    YAZIPANE_USER_WEZTERM = os.getenv 'YAZIPANE_USER_WEZTERM',
    YAZIPANE_STATE_DIR = os.getenv 'YAZIPANE_STATE_DIR',
    YAZIPANE_WARNINGS = os.getenv 'YAZIPANE_WARNINGS',
    YAZIPANE_DEBUG = os.getenv 'YAZIPANE_DEBUG',
    YAZIPANE_LOG_DIR = os.getenv 'YAZIPANE_LOG_DIR',
    YAZI_LOG = os.getenv 'YAZI_LOG',
    YAZIPANE_PEER = peer,
    YAZIPANE_SIDE = side,
  }
end

wezterm.on('gui-startup', function()
  local _, left, window = mux.spawn_window {
    args = { yazi, '--client-id', left_id, left_dir },
    cwd = left_dir,
    set_environment_variables = pane_env(right_id, 'left'),
  }
  local right = left:split {
    direction = 'Right',
    size = 0.5,
    args = { yazi, '--client-id', right_id, right_dir },
    cwd = right_dir,
    set_environment_variables = pane_env(left_id, 'right'),
  }
  -- WezTerm のペイン ID → yazi のクライアント ID（設定の再読み込みでも消えないよう GLOBAL に置く）
  wezterm.GLOBAL.yazipane_ids = {
    [tostring(left:pane_id())] = left_id,
    [tostring(right:pane_id())] = right_id,
  }
  left:activate()
  -- 前回のウィンドウの位置があれば yazipane.exe が復元するので、最大化しない
  if os.getenv 'YAZIPANE_RESTORE_WINDOW' ~= '1' then
    window:gui_window():maximize()
  end
end)

-- ---- 1 画面 / 2 画面の切り替え ----
-- 1 画面（ペインのズーム）にしたら yazi を普段の 3 列表示に、2 画面に戻したら 2 画面用の表示に戻す。

local ya = os.getenv 'YAZIPANE_YA'

local function notify_layout(window, pane, mode)
  local ids = wezterm.GLOBAL.yazipane_ids or {}
  local id = ids[tostring(pane:pane_id())]
  if not id then
    return
  end
  if not ya or ya == '' then
    -- 切り替えのたびに出すとうるさいので、1 回だけ知らせる
    if window and not wezterm.GLOBAL.yazipane_no_ya_notified then
      wezterm.GLOBAL.yazipane_no_ya_notified = true
      window:toast_notification('yazipane', 'ya.exe が見つからないため、yazi の列の表示を切り替えられません（Alt+L で手動で切り替えられます）', nil, 5000)
    end
    return
  end
  wezterm.background_child_process { ya, 'emit-to', id, 'plugin', 'yazipane', 'layout-' .. mode }
end

local function is_zoomed(tab)
  for _, p in ipairs(tab:panes_with_info()) do
    if p.is_zoomed then
      return true
    end
  end
  return false
end

--- ズーム状態が前回から変わっていれば yazi に伝える。
--- キー操作だけでなく、どんな方法でズームしても追従できるよう定期的な確認（poll）からも呼ぶ。
local function sync_layout(window, tab)
  local key = 'yazipane_zoom_' .. tostring(tab:tab_id())
  local zoomed = is_zoomed(tab)
  local previous = wezterm.GLOBAL[key]
  if previous == zoomed then
    return
  end
  wezterm.GLOBAL[key] = zoomed
  -- 最初の確認では今の状態を覚えるだけ（起動直後の yazi は 2 画面用の表示なので、伝えることはない）
  if previous == nil and not zoomed then
    return
  end
  if zoomed then
    -- 1 画面: 表示中（ズーム中）のペインを yazi 本来の 3 列表示にする
    for _, p in ipairs(tab:panes_with_info()) do
      if p.is_zoomed then
        notify_layout(window, p.pane, 'single')
      end
    end
  else
    -- 2 画面: どのペインがズームされていたかに関係なく、全ペインを 2 画面用の表示にそろえる
    for _, p in ipairs(tab:panes_with_info()) do
      notify_layout(window, p.pane, 'dual')
    end
  end
end

-- 1 画面 / 2 画面の切り替え（Ctrl+Shift+Z）と、1 画面のときにペインを移動したら 2 画面に戻すのは WezTerm の既定の動き。
-- どちらも yazi への通知は下の「定期的な確認」が変化を見つけて行う。

-- 左右のペインを同じ幅に戻す（幅の調整は WezTerm 既定の Ctrl+Shift+Alt+矢印）
local equalize = wezterm.action_callback(function(window, pane)
  local tab = pane:tab()
  if not tab or is_zoomed(tab) then
    return
  end
  local panes = tab:panes_with_info()
  if #panes ~= 2 then
    return
  end
  table.sort(panes, function(a, b) return a.left < b.left end)
  local left = panes[1]
  local delta = left.width - math.floor((left.width + panes[2].width) / 2)
  -- 左のペインの右端を動かす（Left で縮め、Right で広げる）
  if delta > 0 then
    window:perform_action(act.AdjustPaneSize { 'Left', delta }, left.pane)
  elseif delta < 0 then
    window:perform_action(act.AdjustPaneSize { 'Right', -delta }, left.pane)
  end
end)

-- ---- エディタなどを開いている間だけ 1 画面にする ----
-- yazi からエディタ（nvim など、画面を止めて開くもの）を開くと、ペインの前面のプロセスが yazi 以外になる。
-- それが続いていたらそのペインを 1 画面にし、yazi に戻ったら 2 画面に戻す。
-- 自分で 1 画面にしていた場合と、開いている途中で自分で 2 画面に戻した場合は、そのままにする。

local DEBUG_LOG = os.getenv 'YAZIPANE_DEBUG' == '1' and os.getenv 'YAZIPANE_LOG_DIR'
local function dbg(msg)
  if DEBUG_LOG then
    local f = io.open(DEBUG_LOG .. '\\wezterm.log', 'a')
    if f then
      f:write(tostring(os.date '%H:%M:%S '), msg, '\n')
      f:close()
    end
  end
end

-- yazi が裏で一瞬だけ起動するもの（プレビュー、Git の状態、yazipane.exe のサブコマンドなど）は数えない
local BACKGROUND = {
  ['yazi.exe'] = true, ['ya.exe'] = true, ['yazipane.exe'] = true, ['git.exe'] = true, ['file.exe'] = true,
  ['conhost.exe'] = true, ['openconsole.exe'] = true,
}
-- 前面が yazi 以外になってから 1 画面にするまでの回数（定期的な確認の間隔ごと。一瞬のものを除くため）
local BUSY_CHECKS = 2

--- ペインの前面のプロセス（名前を小文字で、と表示用のコマンドライン）。無ければ nil。
--- Windows の WezTerm は、終了したプロセスを前面として報告し続けることがあるので、まだ動いているかも確かめる。
local function foreground(pane)
  local ok, info = pcall(function() return pane:get_foreground_process_info() end)
  if not ok or not info or not info.executable then
    return nil
  end
  if wezterm.procinfo and not wezterm.procinfo.get_info_for_pid(info.pid) then
    return nil
  end
  local name = (info.executable:match '[^\\/]+$' or info.executable):lower()
  return name, table.concat(info.argv or {}, ' ')
end

-- ペインごとの状態は wezterm.GLOBAL.yazipane_busy に置く。
-- WezTerm は途中で設定の Lua を作り直すことがあるので、ローカル変数では状態が消えたり二重になったりする。
-- GLOBAL の中身は書き換えずに、毎回新しい表を作って入れ直す。
local function auto_zoom(tab)
  local ids = wezterm.GLOBAL.yazipane_ids or {}
  local old = wezterm.GLOBAL.yazipane_busy or {}
  local state = {}
  for _, p in ipairs(tab:panes_with_info()) do
    local key = tostring(p.pane:pane_id())
    if ids[key] then
      local name, cmdline = foreground(p.pane)
      local busy = name ~= nil and not BACKGROUND[name]
      local prev = old[key] or {}
      local s = {
        name = name,
        count = busy and (prev.count or 0) + 1 or 0,
        handled = prev.handled,
        zoomed_by_us = prev.zoomed_by_us,
      }
      if name ~= prev.name then
        dbg(string.format('pane %s foreground: %s (%s)', key, tostring(name), tostring(cmdline)))
      end

      if s.count >= BUSY_CHECKS and not s.handled then
        -- 1 回だけ処理する（途中で自分で 2 画面に戻したら、閉じるまでそのまま）
        s.handled = true
        if not is_zoomed(tab) then
          p.pane:activate()
          tab:set_zoomed(true)
          s.zoomed_by_us = true
          dbg(string.format('pane %s: %s を開いている間は 1 画面にする', key, name))
        end
      elseif s.count == 0 and s.handled then
        s.handled = false
        if s.zoomed_by_us and is_zoomed(tab) then
          tab:set_zoomed(false)
          dbg(string.format('pane %s: yazi に戻ったので 2 画面に戻す', key))
        end
        s.zoomed_by_us = false
      end
      state[key] = s
    end
  end
  wezterm.GLOBAL.yazipane_busy = state
end

-- ---- 定期的な確認 ----
-- 1 画面 / 2 画面の変化と、エディタなどの開閉を CHECK_INTERVAL 秒ごとに確かめる。
-- タブバーを隠しているので update-status は定期的には呼ばれない（画面の更新などのときだけ）。
-- そこで update-status の中からタイマー（wezterm.time.call_after）を始めて回し続ける。
-- （gui-startup の中で始めたタイマーは動かなかった。設定の Lua が作り直されるとタイマーも止まるので、
--   最後に動いた時刻を GLOBAL に残し、止まっていたら次の update-status で始め直す。
--   古いタイマーが残っていても、自分が最新でなければ止まる）

local CHECK_INTERVAL = 0.3

local function check(window)
  local tab = window:active_tab()
  if tab then
    local ok, err = pcall(function()
      auto_zoom(tab)
      sync_layout(window, tab)
    end)
    if not ok then
      dbg('check: ' .. tostring(err))
    end
  end
end

local function tick(window, id)
  if wezterm.GLOBAL.yazipane_timer ~= id then
    return
  end
  wezterm.GLOBAL.yazipane_timer_beat = os.time()
  check(window)
  wezterm.time.call_after(CHECK_INTERVAL, function() tick(window, id) end)
end

local function ensure_timer(window)
  local beat = wezterm.GLOBAL.yazipane_timer_beat
  if beat and os.time() - beat <= 2 then
    return
  end
  local id = (wezterm.GLOBAL.yazipane_timer or 0) + 1
  wezterm.GLOBAL.yazipane_timer = id
  wezterm.GLOBAL.yazipane_timer_beat = os.time()
  dbg('timer start ' .. id)
  wezterm.time.call_after(CHECK_INTERVAL, function() tick(window, id) end)
end

wezterm.on('update-status', function(window, _)
  ensure_timer(window)
  check(window)
end)

-- ウィンドウタイトル: 左右のフォルダ名（yazi のタイトル "Yazi: <名前>" から取る）と 1 画面かどうか
wezterm.on('format-window-title', function(tab, _, _, panes, _)
  local list = {}
  for _, p in ipairs(panes or {}) do
    list[#list + 1] = p
  end
  table.sort(list, function(a, b) return a.left < b.left end)

  local names, zoomed = {}, false
  for _, p in ipairs(list) do
    names[#names + 1] = (p.title:gsub('^Yazi: ', ''))
    zoomed = zoomed or p.is_zoomed
  end
  if zoomed then
    local name = (tab.active_pane.title:gsub('^Yazi: ', ''))
    return 'yazipane [1画面] — ' .. name
  end
  return 'yazipane — ' .. table.concat(names, '  │  ')
end)

-- ---- 設定 ----
-- 普段の WezTerm 設定（フォント、配色、透過、IME など）を土台にし、yazipane に必要な設定だけを上書きする。

local function load_user_config()
  local path = os.getenv 'YAZIPANE_USER_WEZTERM'
  if not path or path == '' then
    return nil
  end
  -- 普段の設定が同じフォルダのモジュールを require できるようにする
  local dir = path:match '^(.*)[/\\]'
  if dir then
    package.path = dir .. '/?.lua;' .. dir .. '/?/init.lua;' .. package.path
  end
  local ok, user = pcall(dofile, path)
  if not ok then
    wezterm.log_error('yazipane: 普段の WezTerm 設定を読み込めません: ' .. tostring(user))
    return nil
  end
  return type(user) == 'table' and user or nil
end

local user = load_user_config()
if user then
  for k, v in pairs(user) do
    config[k] = v
  end
end

config.hide_tab_bar_if_only_one_tab = true
-- yazi は自前でスクロールするので、ターミナルのスクロールバーは不要
config.enable_scroll_bar = false
-- 1 画面 / 2 画面の変化と、エディタなどの開閉を update-status で確かめるので、間隔を短めにする
config.status_update_interval = 300
-- この設定ファイルは yazipane.exe が起動のたびに書き出すもので、手で編集しない。
-- 同じフォルダには cd のたびに書き換わるファイル（last-*.txt など）があり、自動の再読み込みが何度も起きて
-- 定期的な確認のタイマーが止まる（普段の設定の読み込みも毎回やり直しになる）ので、自動では読み直さない。
config.automatically_reload_config = false
config.window_close_confirmation = 'NeverPrompt'
config.exit_behavior = 'Close'
-- 非アクティブなペインを暗くして、どちらにフォーカスがあるか分かりやすくする（普段の設定にあればそちらを使う）
if not config.inactive_pane_hsb then
  config.inactive_pane_hsb = { saturation = 0.7, brightness = 0.5 }
end

-- WezTerm の既定のキーで足りるものは割り当てない（Ctrl+Shift+Z の 1 画面 / 2 画面、Ctrl+Shift+Alt+矢印の幅の調整など）。
local our_keys = {
  -- yazi の Tab と衝突しないよう Ctrl+Tab でペインを切り替える（WezTerm の既定ではタブの切り替え）
  { key = 'Tab', mods = 'CTRL', action = act.ActivatePaneDirection 'Next' },
  { key = 'Tab', mods = 'CTRL|SHIFT', action = act.ActivatePaneDirection 'Prev' },
  -- 左右のペインを同じ幅に戻す（WezTerm には無い）
  { key = 'e', mods = 'CTRL|SHIFT', action = equalize },
}

-- 普段のキー割り当てを残しつつ、yazipane のキーと重なるものは yazipane を優先する
-- mods は書き順が違っても同じキーとみなす（'SHIFT|CTRL' と 'CTRL|SHIFT' など）
local function key_id(k)
  local mods = {}
  for m in string.upper(tostring(k.mods or '')):gmatch '[^|%s]+' do
    local normalized = ({ OPT = 'ALT', META = 'ALT', CMD = 'SUPER', WIN = 'SUPER' })[m] or m
    mods[#mods + 1] = normalized
  end
  table.sort(mods)
  return string.lower(tostring(k.key)) .. '/' .. table.concat(mods, '|')
end
local ours = {}
for _, k in ipairs(our_keys) do
  ours[key_id(k)] = true
end
local keys = {}
for _, k in ipairs(user and user.keys or {}) do
  if not ours[key_id(k)] then
    keys[#keys + 1] = k
  end
end
for _, k in ipairs(our_keys) do
  keys[#keys + 1] = k
end
config.keys = keys

return config
