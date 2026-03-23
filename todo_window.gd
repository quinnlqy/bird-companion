extends Window

const SAVE_PATH     := "user://todos.json"
const SYNC_INTERVAL := 6.0 * 3600.0

const PRIORITY_HIGH   := "high"
const PRIORITY_MEDIUM := "medium"
const PRIORITY_LOW    := "low"

var _todos: Array = []
var _list_container: VBoxContainer
var _input: LineEdit
var _sync_btn: Button
var _sync_status_label: Label
var _sync_timer := 0.0
var _waiting_for_sync_response := false

signal request_ws_send(method: String, params: Dictionary)

var _drag_active      := false
var _drag_start_mouse := Vector2i.ZERO
var _drag_start_win   := Vector2i.ZERO


func _ready() -> void:
	# 窗口设置
	title            = ""
	unresizable      = false
	borderless       = true
	always_on_top    = true
	transparent      = true
	transparent_bg   = true
	min_size         = Vector2i(300, 420)
	size             = Vector2i(300, 480)
	gui_embed_subwindows = false

	_build_ui()
	_load_todos()
	_refresh_list()


func _process(delta: float) -> void:
	_sync_timer += delta
	if _sync_timer >= SYNC_INTERVAL:
		_sync_timer = 0.0
		request_sync_from_openclaw()


func _build_ui() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color                   = Color(0.12, 0.12, 0.15, 0.97)
	style.corner_radius_top_left     = 8
	style.corner_radius_top_right    = 8
	style.corner_radius_bottom_left  = 8
	style.corner_radius_bottom_right = 8

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	# 标题栏
	var title_bar := HBoxContainer.new()
	title_bar.custom_minimum_size = Vector2(0, 30)
	title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	title_bar.gui_input.connect(_on_title_bar_gui_input)
	root.add_child(title_bar)

	var drag_hint := Label.new()
	drag_hint.text = "☰"
	drag_hint.modulate = Color(1,1,1,0.5)
	drag_hint.custom_minimum_size = Vector2(20, 0)
	drag_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	title_bar.add_child(drag_hint)

	var title_lbl := Label.new()
	title_lbl.text = "📝 Todo List"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	title_bar.add_child(title_lbl)

	_sync_btn = Button.new()
	_sync_btn.text = "🔄"
	_sync_btn.flat = true
	_sync_btn.tooltip_text = "从 OpenClaw 同步"
	_sync_btn.pressed.connect(request_sync_from_openclaw)
	title_bar.add_child(_sync_btn)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.pressed.connect(func(): hide())
	title_bar.add_child(close_btn)

	_sync_status_label = Label.new()
	_sync_status_label.add_theme_font_size_override("font_size", 10)
	_sync_status_label.modulate = Color(0.6, 0.9, 0.6, 0.8)
	root.add_child(_sync_status_label)

	root.add_child(HSeparator.new())

	var input_row := HBoxContainer.new()
	root.add_child(input_row)

	_input = LineEdit.new()
	_input.placeholder_text = "添加待办..."
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(func(_t): _on_add_pressed())
	input_row.add_child(_input)

	var add_btn := Button.new()
	add_btn.text = "+"
	add_btn.custom_minimum_size = Vector2(32, 0)
	add_btn.pressed.connect(_on_add_pressed)
	input_row.add_child(add_btn)

	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	_list_container = VBoxContainer.new()
	_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_container.add_theme_constant_override("separation", 4)
	scroll.add_child(_list_container)


func _refresh_list() -> void:
	for child in _list_container.get_children():
		child.queue_free()

	var groups := {
		PRIORITY_HIGH:   {"label": "🔴 紧急", "items": []},
		PRIORITY_MEDIUM: {"label": "🟡 普通", "items": []},
		PRIORITY_LOW:    {"label": "🟢 随时", "items": []},
	}
	var order := [PRIORITY_HIGH, PRIORITY_MEDIUM, PRIORITY_LOW]

	for i in _todos.size():
		var item: Dictionary = _todos[i]
		var p: String = item.get("priority", PRIORITY_MEDIUM)
		if not groups.has(p): p = PRIORITY_MEDIUM
		groups[p]["items"].append({"idx": i, "item": item})

	for p in order:
		var g = groups[p]
		if g["items"].is_empty(): continue

		var header := Label.new()
		header.text = g["label"]
		header.add_theme_font_size_override("font_size", 11)
		header.modulate = Color(1,1,1,0.55)
		_list_container.add_child(header)

		for entry in g["items"]:
			_list_container.add_child(_build_item_row(entry["idx"], entry["item"]))


func _build_item_row(i: int, item: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()

	var check := CheckButton.new()
	check.button_pressed = item.get("done", false)
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.text = item.get("text", "")
	check.toggled.connect(_on_item_toggled.bind(i))
	if item.get("done", false):
		check.modulate = Color(1,1,1,0.4)
	row.add_child(check)

	var p_btn := Button.new()
	p_btn.text = _priority_icon(item.get("priority", PRIORITY_MEDIUM))
	p_btn.flat = true
	p_btn.custom_minimum_size = Vector2(28, 0)
	p_btn.pressed.connect(_on_priority_cycle.bind(i))
	row.add_child(p_btn)

	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.flat = true
	del_btn.custom_minimum_size = Vector2(28, 0)
	del_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	del_btn.pressed.connect(_on_item_deleted.bind(i))
	row.add_child(del_btn)

	return row


func _priority_icon(p: String) -> String:
	match p:
		PRIORITY_HIGH: return "🔴"
		PRIORITY_LOW:  return "🟢"
		_:             return "🟡"


func _on_priority_cycle(index: int) -> void:
	var cur: String = _todos[index].get("priority", PRIORITY_MEDIUM)
	match cur:
		PRIORITY_HIGH:   _todos[index]["priority"] = PRIORITY_MEDIUM
		PRIORITY_MEDIUM: _todos[index]["priority"] = PRIORITY_LOW
		_:               _todos[index]["priority"] = PRIORITY_HIGH
	_todos[index]["updated_at"] = Time.get_unix_time_from_system()
	_save_todos()
	_refresh_list()


func _on_title_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_drag_active = event.pressed
		if event.pressed:
			_drag_start_mouse = DisplayServer.mouse_get_position()
			_drag_start_win   = position
	elif event is InputEventMouseMotion and _drag_active:
		var delta := DisplayServer.mouse_get_position() - _drag_start_mouse
		position = _drag_start_win + delta


func _on_add_pressed() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty(): return
	_todos.append({
		"text": text, "done": false,
		"priority": PRIORITY_MEDIUM,
		"updated_at": Time.get_unix_time_from_system()
	})
	_input.text = ""
	_save_todos()
	_refresh_list()


func _on_item_toggled(pressed: bool, index: int) -> void:
	_todos[index]["done"] = pressed
	_todos[index]["updated_at"] = Time.get_unix_time_from_system()
	_save_todos()
	_refresh_list()


func _on_item_deleted(index: int) -> void:
	_todos.remove_at(index)
	_save_todos()
	_refresh_list()


func _save_todos() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_todos))
		file.close()


func _load_todos() -> void:
	if not FileAccess.file_exists(SAVE_PATH): return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		file.close()
		if data is Array:
			for item in data:
				if not item.has("priority"):   item["priority"]   = PRIORITY_MEDIUM
				if not item.has("updated_at"): item["updated_at"] = 0
			_todos = data


func request_sync_from_openclaw() -> void:
	if _waiting_for_sync_response: return
	_waiting_for_sync_response = true
	_set_sync_status("⏳ 同步中...")
	emit_signal("request_ws_send", "chat.send", {
		"sessionKey":     "agent:main:main",
		"idempotencyKey": "todo-sync-%d" % Time.get_unix_time_from_system(),
		"message": "请帮我读取 /root/.openclaw/workspace/TODO.md 的完整内容，然后以如下 JSON 格式回复，不要有任何其他文字：\n{\"todo_sync\": true, \"items\": [{\"text\": \"任务文字\", \"done\": false, \"priority\": \"high\"}]}\npriority 只能是 high / medium / low，对应文件里的 🔴 / 🟡 / 🟢 分组，✅ Done 下面的条目 done=true。"
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
	if parsed == null or not parsed.get("todo_sync", false):
		_set_sync_status("❌ 响应格式错误")
		_waiting_for_sync_response = false
		return
	_merge_todos(parsed.get("items", []))
	_waiting_for_sync_response = false
	_push_todos_to_openclaw()


func _merge_todos(remote_items: Array) -> void:
	var local_map := {}
	for item in _todos:
		local_map[item["text"]] = item
	var remote_map := {}
	for item in remote_items:
		if not item.has("updated_at"): item["updated_at"] = 0
		if not item.has("priority"):   item["priority"]   = PRIORITY_MEDIUM
		remote_map[item["text"]] = item
	var merged := []
	for item in _todos:
		var key: String = item["text"]
		if remote_map.has(key):
			var r = remote_map[key]
			merged.append(r.duplicate() if r.get("updated_at",0) > item.get("updated_at",0) else item.duplicate())
			remote_map.erase(key)
		else:
			merged.append(item.duplicate())
	for key: String in remote_map:
		merged.append(remote_map[key].duplicate())
	_todos = merged
	_save_todos()
	_refresh_list()
	_set_sync_status("✅ 同步完成 " + _time_str())


func _push_todos_to_openclaw() -> void:
	var now  := Time.get_datetime_string_from_system().substr(0, 10)
	var lines := ["TODO", "Last updated: " + now, ""]
	var groups := {
		PRIORITY_HIGH:   {"header": "🔴 High Priority", "items": []},
		PRIORITY_MEDIUM: {"header": "🟡 Medium Priority","items": []},
		PRIORITY_LOW:    {"header": "🟢 Nice to Have",   "items": []},
	}
	var done_items := []
	for item in _todos:
		if item.get("done", false): done_items.append(item); continue
		var p: String = item.get("priority", PRIORITY_MEDIUM)
		if not groups.has(p): p = PRIORITY_MEDIUM
		groups[p]["items"].append(item)
	for p in [PRIORITY_HIGH, PRIORITY_MEDIUM, PRIORITY_LOW]:
		lines.append(groups[p]["header"])
		for item in groups[p]["items"]: lines.append("[ ] " + item["text"])
		lines.append("")
	lines.append("✅ Done")
	for item in done_items: lines.append("[x] " + item["text"])
	emit_signal("request_ws_send", "chat.send", {
		"sessionKey":     "agent:main:main",
		"idempotencyKey": "todo-push-%d" % Time.get_unix_time_from_system(),
		"message": "请用以下内容完整覆写 /root/.openclaw/workspace/TODO.md，不要修改任何内容，直接写入：\n\n" + "\n".join(lines)
	})


func _set_sync_status(text: String) -> void:
	if is_instance_valid(_sync_status_label):
		_sync_status_label.text = text


func _time_str() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%02d:%02d" % [t["hour"], t["minute"]]
