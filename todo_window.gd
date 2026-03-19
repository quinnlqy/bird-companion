extends PanelContainer

const SAVE_PATH := "user://todos.json"

var _todos: Array = []
var _list_container: VBoxContainer
var _input: LineEdit

# 拖拽 OS 窗口
var _drag_active      := false
var _drag_start_mouse := Vector2i.ZERO
var _drag_start_win   := Vector2i.ZERO


func _ready() -> void:
	# custom_minimum_size 决定 Window size（Window.size 设为 320x440）
	custom_minimum_size = Vector2(300, 420)
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical   = SIZE_EXPAND_FILL
	_build_ui()
	_load_todos()
	_refresh_list()


func _build_ui() -> void:
	# ── 外层 Margin ──────────────────────────────────────
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = SIZE_EXPAND_FILL
	margin.size_flags_vertical   = SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = SIZE_EXPAND_FILL
	root.size_flags_vertical   = SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	# ── 标题栏（拖拽移动 OS 窗口）────────────────────────
	var title_bar := HBoxContainer.new()
	title_bar.custom_minimum_size = Vector2(0, 30)
	title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	title_bar.gui_input.connect(_on_title_bar_gui_input)
	root.add_child(title_bar)

	var drag_hint := Label.new()
	drag_hint.text = "☰"
	drag_hint.modulate = Color(1, 1, 1, 0.5)
	drag_hint.custom_minimum_size = Vector2(20, 0)
	drag_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	title_bar.add_child(drag_hint)

	var title_lbl := Label.new()
	title_lbl.text = "📝 Todo List"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	title_bar.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.pressed.connect(func(): hide())  # 隐藏面板自身（非 Window）
	title_bar.add_child(close_btn)

	root.add_child(HSeparator.new())

	# ── 输入行 ────────────────────────────────────────────
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

	# ── 列表区域（可滚动）────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	_list_container = VBoxContainer.new()
	_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_container.add_theme_constant_override("separation", 4)
	scroll.add_child(_list_container)


# 拖拽标题栏 → 移动面板自身（在全屏窗口内）
func _on_title_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_drag_active = event.pressed
		if event.pressed:
			_drag_start_mouse = DisplayServer.mouse_get_position()
			_drag_start_win   = Vector2i(int(position.x), int(position.y))
	elif event is InputEventMouseMotion and _drag_active:
		var delta := DisplayServer.mouse_get_position() - _drag_start_mouse
		position = Vector2(_drag_start_win + delta)



func _refresh_list() -> void:
	for child in _list_container.get_children():
		child.queue_free()

	for i in _todos.size():
		var item: Dictionary = _todos[i]
		var row := HBoxContainer.new()
		_list_container.add_child(row)

		var check := CheckButton.new()
		check.button_pressed = item.done
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		check.text = item.text
		check.toggled.connect(_on_item_toggled.bind(i))
		if item.done:
			check.modulate = Color(1, 1, 1, 0.45)
		row.add_child(check)

		var del_btn := Button.new()
		del_btn.text = "✕"
		del_btn.flat = true
		del_btn.custom_minimum_size = Vector2(28, 0)
		del_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		del_btn.pressed.connect(_on_item_deleted.bind(i))
		row.add_child(del_btn)


func _on_add_pressed() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty():
		return
	_todos.append({"text": text, "done": false})
	_input.text = ""
	_save_todos()
	_refresh_list()


func _on_item_toggled(pressed: bool, index: int) -> void:
	_todos[index].done = pressed
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
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		file.close()
		if data is Array:
			_todos = data
