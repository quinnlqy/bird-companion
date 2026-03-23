extends Window

const SAVE_PATH     := "user://events.json"
const SYNC_INTERVAL := 6.0 * 3600.0

signal request_ws_send(method: String, params: Dictionary)

var _events: Array = []
var _sync_timer               := 0.0
var _waiting_for_sync_response := false

enum View { MONTH, DAY, DETAIL, ADD }
var _view:               View   = View.MONTH
var _view_year:          int
var _view_month:         int
var _selected_date:      String = ""
var _selected_event_idx: int    = -1

var _content_root:    VBoxContainer
var _sync_status_lbl: Label

var _drag_active      := false
var _drag_start_mouse := Vector2i.ZERO
var _drag_start_win   := Vector2i.ZERO

const WEEK_HEADERS := ["日","一","二","三","四","五","六"]
const EVENT_COLORS := [
	Color(0.40, 0.70, 1.00, 0.90),
	Color(0.55, 0.88, 0.55, 0.90),
	Color(1.00, 0.70, 0.30, 0.90),
	Color(0.85, 0.50, 1.00, 0.90),
	Color(1.00, 0.55, 0.55, 0.90),
	Color(0.40, 0.90, 0.85, 0.90),
]


func _ready() -> void:
	title            = ""
	unresizable      = false
	borderless       = true
	always_on_top    = true
	transparent      = true
	transparent_bg   = true
	min_size         = Vector2i(340, 560)
	size             = Vector2i(340, 560)
	gui_embed_subwindows = false

	var now := Time.get_datetime_dict_from_system()
	_view_year  = now["year"]
	_view_month = now["month"]
	_load_events()
	_build_shell()
	_render()


func _process(delta: float) -> void:
	_sync_timer += delta
	if _sync_timer >= SYNC_INTERVAL:
		_sync_timer = 0.0
		request_sync_from_openclaw()


func _build_shell() -> void:
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color                   = Color(0.12, 0.12, 0.15, 0.97)
	bg_style.corner_radius_top_left     = 8
	bg_style.corner_radius_top_right    = 8
	bg_style.corner_radius_bottom_left  = 8
	bg_style.corner_radius_bottom_right = 8

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", bg_style)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	var outer := VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 6)
	margin.add_child(outer)

	# 标题栏
	var title_bar := HBoxContainer.new()
	title_bar.custom_minimum_size = Vector2(0, 30)
	title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	title_bar.gui_input.connect(_on_title_bar_gui_input)
	outer.add_child(title_bar)

	var drag_hint := Label.new()
	drag_hint.text = "☰"
	drag_hint.modulate = Color(1,1,1,0.5)
	drag_hint.custom_minimum_size = Vector2(20, 0)
	drag_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	title_bar.add_child(drag_hint)

	var title_lbl := Label.new()
	title_lbl.text = "📅 日历"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	title_bar.add_child(title_lbl)

	var sync_btn := Button.new()
	sync_btn.text = "🔄"
	sync_btn.flat = true
	sync_btn.pressed.connect(request_sync_from_openclaw)
	title_bar.add_child(sync_btn)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.pressed.connect(func(): hide())
	title_bar.add_child(close_btn)

	_sync_status_lbl = Label.new()
	_sync_status_lbl.add_theme_font_size_override("font_size", 10)
	_sync_status_lbl.modulate = Color(0.6, 0.9, 0.6, 0.8)
	outer.add_child(_sync_status_lbl)

	outer.add_child(HSeparator.new())

	_content_root = VBoxContainer.new()
	_content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_root.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_content_root.add_theme_constant_override("separation", 4)
	outer.add_child(_content_root)


func _render() -> void:
	for c in _content_root.get_children():
		c.queue_free()
	match _view:
		View.MONTH:  _render_month()
		View.DAY:    _render_day()
		View.DETAIL: _render_detail()
		View.ADD:    _render_add()


func _render_month() -> void:
	var nav := HBoxContainer.new()
	_content_root.add_child(nav)

	var prev_btn := Button.new()
	prev_btn.text = " ‹ "
	prev_btn.flat = true
	prev_btn.pressed.connect(_prev_month)
	nav.add_child(prev_btn)

	var nav_lbl := Label.new()
	nav_lbl.text = "%d年%d月" % [_view_year, _view_month]
	nav_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	nav_lbl.add_theme_font_size_override("font_size", 15)
	nav.add_child(nav_lbl)

	var next_btn := Button.new()
	next_btn.text = " › "
	next_btn.flat = true
	next_btn.pressed.connect(_next_month)
	nav.add_child(next_btn)

	var grid := GridContainer.new()
	grid.columns = 7
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_root.add_child(grid)

	for h in WEEK_HEADERS:
		var lbl := Label.new()
		lbl.text = h
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.modulate = Color(1,1,1,0.45)
		lbl.custom_minimum_size = Vector2(44, 22)
		grid.add_child(lbl)

	var first_wd      := _get_weekday(_view_year, _view_month, 1)
	var days_in_month := _days_in_month(_view_year, _view_month)
	var today         := Time.get_datetime_dict_from_system()

	for _i in first_wd:
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(44, 68)
		grid.add_child(sp)

	for d in range(1, days_in_month + 1):
		var date_str   := "%04d-%02d-%02d" % [_view_year, _view_month, d]
		var is_today: bool = (today["year"] == _view_year and today["month"] == _view_month and today["day"] == d)
		var day_events := _events_for_date(date_str)

		var cell := VBoxContainer.new()
		cell.custom_minimum_size = Vector2(44, 68)
		grid.add_child(cell)

		var day_btn := Button.new()
		day_btn.text = str(d)
		day_btn.flat = true
		day_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		day_btn.pressed.connect(_on_day_pressed.bind(date_str))
		if is_today:
			day_btn.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
			day_btn.add_theme_font_size_override("font_size", 15)
		else:
			day_btn.add_theme_font_size_override("font_size", 13)
		cell.add_child(day_btn)

		var shown := 0
		for entry in day_events:
			if shown >= 2:
				var more_lbl := Label.new()
				more_lbl.text = "+%d" % (day_events.size() - 2)
				more_lbl.add_theme_font_size_override("font_size", 9)
				more_lbl.modulate = Color(1,1,1,0.5)
				more_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				more_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cell.add_child(more_lbl)
				break
			var evt: Dictionary = entry["event"]
			var color := _event_color(evt.get("title",""))
			var evt_bg := PanelContainer.new()
			var s := StyleBoxFlat.new()
			s.bg_color = Color(color.r, color.g, color.b, 0.25)
			s.corner_radius_top_left = 3
			s.corner_radius_top_right = 3
			s.corner_radius_bottom_left = 3
			s.corner_radius_bottom_right = 3
			evt_bg.add_theme_stylebox_override("panel", s)
			evt_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.add_child(evt_bg)
			var evt_lbl := Label.new()
			evt_lbl.text = evt.get("title","")
			evt_lbl.add_theme_font_size_override("font_size", 9)
			evt_lbl.add_theme_color_override("font_color", color)
			evt_lbl.clip_text = true
			evt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			evt_bg.add_child(evt_lbl)
			shown += 1


func _render_day() -> void:
	var header := HBoxContainer.new()
	_content_root.add_child(header)

	var back_btn := Button.new()
	back_btn.text = "‹ 返回"
	back_btn.flat = true
	back_btn.pressed.connect(func(): _view = View.MONTH; _render())
	header.add_child(back_btn)

	var date_lbl := Label.new()
	date_lbl.text = _format_date_display(_selected_date)
	date_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	date_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	date_lbl.add_theme_font_size_override("font_size", 14)
	header.add_child(date_lbl)

	_content_root.add_child(HSeparator.new())

	var events := _events_for_date(_selected_date)
	if events.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "这天没有事件"
		empty_lbl.modulate = Color(1,1,1,0.4)
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_content_root.add_child(empty_lbl)
	else:
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_content_root.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 2)
		scroll.add_child(list)
		for entry in events:
			var idx: int        = entry["idx"]
			var evt: Dictionary = entry["event"]
			var evt_btn := Button.new()
			evt_btn.text = "  • " + evt.get("title","")
			evt_btn.flat = true
			evt_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			evt_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			evt_btn.pressed.connect(func(): _selected_event_idx = idx; _view = View.DETAIL; _render())
			list.add_child(evt_btn)

	_content_root.add_child(HSeparator.new())
	var add_btn := Button.new()
	add_btn.text = "+ 添加事件"
	add_btn.flat = true
	add_btn.pressed.connect(func(): _view = View.ADD; _render())
	_content_root.add_child(add_btn)


func _render_detail() -> void:
	if _selected_event_idx < 0 or _selected_event_idx >= _events.size():
		_view = View.DAY; _render(); return

	var evt: Dictionary = _events[_selected_event_idx]

	var back_btn := Button.new()
	back_btn.text = "‹ 返回"
	back_btn.flat = true
	back_btn.pressed.connect(func(): _view = View.DAY; _render())
	_content_root.add_child(back_btn)

	_content_root.add_child(HSeparator.new())

	var date_lbl := Label.new()
	date_lbl.text = _format_date_display(evt.get("date",""))
	date_lbl.add_theme_font_size_override("font_size", 11)
	date_lbl.modulate = Color(1,1,1,0.5)
	_content_root.add_child(date_lbl)

	var title_lbl := Label.new()
	title_lbl.text = evt.get("title","")
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content_root.add_child(title_lbl)

	_content_root.add_child(HSeparator.new())

	var detail: String = evt.get("detail","")
	if detail.is_empty():
		var nd := Label.new()
		nd.text = "（没有详细说明）"
		nd.modulate = Color(1,1,1,0.35)
		_content_root.add_child(nd)
	else:
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_content_root.add_child(scroll)
		var dl := Label.new()
		dl.text = detail
		dl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(dl)

	var del_btn := Button.new()
	del_btn.text = "🗑 删除事件"
	del_btn.flat = true
	del_btn.add_theme_color_override("font_color", Color(1,0.4,0.4))
	del_btn.pressed.connect(func():
		_events.remove_at(_selected_event_idx)
		_selected_event_idx = -1
		_save_events()
		_view = View.DAY; _render()
	)
	_content_root.add_child(del_btn)


func _render_add() -> void:
	var back_btn := Button.new()
	back_btn.text = "‹ 返回"
	back_btn.flat = true
	back_btn.pressed.connect(func(): _view = View.DAY; _render())
	_content_root.add_child(back_btn)

	var date_lbl := Label.new()
	date_lbl.text = _format_date_display(_selected_date)
	date_lbl.add_theme_font_size_override("font_size", 12)
	date_lbl.modulate = Color(1,1,1,0.6)
	_content_root.add_child(date_lbl)

	_content_root.add_child(HSeparator.new())

	var t_hint := Label.new()
	t_hint.text = "事件标题"
	t_hint.add_theme_font_size_override("font_size", 11)
	t_hint.modulate = Color(1,1,1,0.5)
	_content_root.add_child(t_hint)

	var title_input := LineEdit.new()
	title_input.placeholder_text = "输入标题..."
	title_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_root.add_child(title_input)

	var d_hint := Label.new()
	d_hint.text = "详细说明（可选）"
	d_hint.add_theme_font_size_override("font_size", 11)
	d_hint.modulate = Color(1,1,1,0.5)
	_content_root.add_child(d_hint)

	var detail_input := TextEdit.new()
	detail_input.placeholder_text = "输入详细说明..."
	detail_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_input.custom_minimum_size   = Vector2(0, 90)
	_content_root.add_child(detail_input)

	var confirm_btn := Button.new()
	confirm_btn.text = "✓ 添加"
	confirm_btn.pressed.connect(func():
		var t := title_input.text.strip_edges()
		if t.is_empty(): return
		_events.append({
			"date": _selected_date, "title": t,
			"detail": detail_input.text.strip_edges(),
			"updated_at": Time.get_unix_time_from_system()
		})
		_save_events()
		_view = View.DAY; _render()
	)
	_content_root.add_child(confirm_btn)


func _event_color(title: String) -> Color:
	return EVENT_COLORS[absi(title.hash()) % EVENT_COLORS.size()]


func _events_for_date(date_str: String) -> Array:
	var result := []
	for i in _events.size():
		if _events[i].get("date","") == date_str:
			result.append({"idx": i, "event": _events[i]})
	return result


func _format_date_display(date_str: String) -> String:
	if date_str.length() < 10: return date_str
	var parts := date_str.split("-")
	if parts.size() < 3: return date_str
	var wd := _get_weekday(int(parts[0]), int(parts[1]), int(parts[2]))
	return "%d月%d日 周%s" % [int(parts[1]), int(parts[2]), ["日","一","二","三","四","五","六"][wd]]


func _get_weekday(year: int, month: int, day: int) -> int:
	var m := month
	var y := year
	if m < 3: m += 12; y -= 1
	var k := y % 100
	var j := y / 100
	var h := (day + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7
	return (h + 6) % 7


func _days_in_month(year: int, month: int) -> int:
	var days := [31,28,31,30,31,30,31,31,30,31,30,31]
	if month == 2 and ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0):
		return 29
	return days[month - 1]


func _prev_month() -> void:
	_view_month -= 1
	if _view_month < 1: _view_month = 12; _view_year -= 1
	_render()


func _next_month() -> void:
	_view_month += 1
	if _view_month > 12: _view_month = 1; _view_year += 1
	_render()


func _on_day_pressed(date_str: String) -> void:
	_selected_date = date_str
	_view = View.DAY
	_render()


func _on_title_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_drag_active = event.pressed
		if event.pressed:
			_drag_start_mouse = DisplayServer.mouse_get_position()
			_drag_start_win   = position
	elif event is InputEventMouseMotion and _drag_active:
		var delta := DisplayServer.mouse_get_position() - _drag_start_mouse
		position = _drag_start_win + delta


func _save_events() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_events))
		file.close()


func _load_events() -> void:
	if not FileAccess.file_exists(SAVE_PATH): return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		file.close()
		if data is Array: _events = data


func request_sync_from_openclaw() -> void:
	if _waiting_for_sync_response: return
	_waiting_for_sync_response = true
	_set_sync_status("⏳ 同步中...")
	emit_signal("request_ws_send", "chat.send", {
		"sessionKey":     "agent:main:main",
		"idempotencyKey": "calendar-sync-%d" % Time.get_unix_time_from_system(),
		"message": "请帮我读取 /root/.openclaw/workspace/CALENDAR.md 的完整内容，如果文件不存在就返回空数组。以如下 JSON 格式回复，不要有任何其他文字：\n{\"calendar_sync\": true, \"events\": [{\"date\": \"YYYY-MM-DD\", \"title\": \"事件标题\", \"detail\": \"详细说明（可为空字符串）\"}]}"
	})


func on_chat_response(text: String) -> void:
	if not _waiting_for_sync_response: return
	var json_start := text.find("{")
	var json_end   := text.rfind("}")
	if json_start == -1 or json_end == -1:
		_set_sync_status("❌ 响应格式错误")
		_waiting_for_sync_response = false
		return
	var parsed = JSON.parse_string(text.substr(json_start, json_end - json_start + 1))
	if parsed == null or not parsed.get("calendar_sync", false):
		_set_sync_status("❌ 响应格式错误")
		_waiting_for_sync_response = false
		return
	_merge_events(parsed.get("events", []))
	_waiting_for_sync_response = false
	_push_events_to_openclaw()


func _merge_events(remote_events: Array) -> void:
	var local_map := {}
	for evt in _events:
		local_map[evt.get("date","") + "|" + evt.get("title","")] = evt
	var remote_map := {}
	for evt in remote_events:
		if not evt.has("updated_at"): evt["updated_at"] = 0
		if not evt.has("detail"):     evt["detail"]     = ""
		remote_map[evt.get("date","") + "|" + evt.get("title","")] = evt
	var merged := []
	for evt in _events:
		var key: String = evt.get("date","") + "|" + evt.get("title","")
		if remote_map.has(key):
			var r = remote_map[key]
			merged.append(r.duplicate() if r.get("updated_at",0) > evt.get("updated_at",0) else evt.duplicate())
			remote_map.erase(key)
		else:
			merged.append(evt.duplicate())
	for key: String in remote_map:
		merged.append(remote_map[key].duplicate())
	_events = merged
	_save_events()
	_render()
	_set_sync_status("✅ 同步完成 " + _time_str())


func _push_events_to_openclaw() -> void:
	var now    := Time.get_datetime_string_from_system().substr(0, 10)
	var lines  := ["CALENDAR", "Last updated: " + now, ""]
	var sorted := _events.duplicate()
	sorted.sort_custom(func(a, b): return a.get("date","") < b.get("date",""))
	var cur_date := ""
	for evt in sorted:
		var d: String = evt.get("date","")
		if d != cur_date:
			if not cur_date.is_empty(): lines.append("")
			lines.append("## " + d)
			cur_date = d
		lines.append("### " + evt.get("title",""))
		if not evt.get("detail","").is_empty():
			lines.append(evt.get("detail",""))
	emit_signal("request_ws_send", "chat.send", {
		"sessionKey":     "agent:main:main",
		"idempotencyKey": "calendar-push-%d" % Time.get_unix_time_from_system(),
		"message": "请用以下内容完整覆写 /root/.openclaw/workspace/CALENDAR.md，不要修改任何内容，直接写入：\n\n" + "\n".join(lines)
	})


func _set_sync_status(text: String) -> void:
	if is_instance_valid(_sync_status_lbl):
		_sync_status_lbl.text = text


func _time_str() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%02d:%02d" % [t["hour"], t["minute"]]
