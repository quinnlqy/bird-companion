extends Node2D

# ── 节点引用 ──────────────────────────────────────────────
@onready var anim_tree: AnimationTree = $AnimationTree
@onready var body: Polygon2D = $body
@onready var status_label: Label = $StatusLabel
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var skeleton: Skeleton2D = $Skeleton2D

var _debug_label: Label
var _todo_panel: Control    # Todo 面板（CanvasLayer 内，主窗口中）
var _todo_btn:   Button

# ── 中转服务器配置 ────────────────────────────────────────
const WS_URL := "ws://106.53.29.28:18789"

var _ws := WebSocketPeer.new()
var _reconnect_delay := 5.0
var _reconnect_timer := 0.0
var _should_reconnect := false

# ── 随机歪头计时器 ────────────────────────────────────────
var _tilt_timer := 0.0
var _next_tilt  := 0.0

# ── 侧面动画防重入 ────────────────────────────────────────
var _is_side_animating := false

# ── 久坐提醒计时器 ────────────────────────────────────────
const SEDENTARY_INTERVAL := 45.0 * 60.0  # 45 分钟（秒）
var _sedentary_timer := 0.0

# ── 休眠计时器 ───────────────────────────────────────────
const SLEEP_INTERVAL := 5.0 * 60.0  # 5 分钟无操作后入睡
var _idle_timer := 0.0

# ── 当前宠物状态 ──────────────────────────────────────────
enum State { IDLE, WORKING, DONE, SLEEPING }
var _state := State.IDLE

# ── 窗口拖拽 ──────────────────────────────────────────────
var _drag_start : Vector2i
var _is_dragging := false

# ── 全局活动检测（鼠标移动 = 用户还在活动）──────────────────
var _last_mouse_pos := Vector2i.ZERO


func _ready() -> void:
	anim_tree.active = true
	get_window().borderless = true
	_next_tilt = randf_range(5.0, 15.0)

	# ── 全屏透明窗口（Bongocat 模式）──────────────────────
	# 先设透明和清除色，再 resize（避免 resize 重置渲染状态）
	get_window().transparent_bg = true
	RenderingServer.set_default_clear_color(Color(0.0, 0.0, 0.0, 0.0))
	# 延迟一帧再做 resize + 定位，确保渲染器初始化完成
	call_deferred("_setup_fullscreen_window")

	# ── 调试标签（显示倒计时）─────────────────────────────
	_debug_label = Label.new()
	_debug_label.position = Vector2(-80, 60)
	_debug_label.custom_minimum_size = Vector2(200, 60)
	_debug_label.add_theme_font_size_override("font_size", 11)
	_debug_label.modulate = Color(1, 1, 0, 0.85)
	add_child(_debug_label)

	_update_status()
	_connect_ws()
	call_deferred("_init_todo")


func _setup_fullscreen_window() -> void:
	var win := get_window()
	var screen_idx  := win.current_screen
	var screen_rect := DisplayServer.screen_get_usable_rect(screen_idx)

	# 必须先禁用内容缩放，视口才能跟随窗口大小变化
	win.content_scale_mode   = Window.CONTENT_SCALE_MODE_DISABLED
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE

	win.position      = screen_rect.position
	win.size          = screen_rect.size
	win.always_on_top = true

	# 等两帧，确保 resize 和缩放模式都生效
	await get_tree().process_frame
	await get_tree().process_frame

	var vp_sz := get_viewport_rect().size
	print("[Window] screen_rect=", screen_rect, "  viewport=", vp_sz)
	position = Vector2(vp_sz.x - 200.0, vp_sz.y - 280.0)
	_reposition_todo_ui()
	_update_mouse_region()


# ── Todo 初始化 ─────────────────────────────────────────
func _init_todo() -> void:
	# CanvasLayer 覆盖整个全屏窗口，用于放置 UI 控件
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(anchor)

	# ── 切换按钮（靠近鸟鸟）──────────────────────────────
	_todo_btn = Button.new()
	_todo_btn.text = "📝 Todo"
	_todo_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_todo_btn.flat = true
	_todo_btn.modulate = Color(1, 1, 1, 0.75)
	_todo_btn.pressed.connect(_on_todo_btn_pressed)
	anchor.add_child(_todo_btn)

	# ── Todo 面板（在主全屏窗口内，无需子 Window）────────
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.97)
	style.corner_radius_top_left    = 8
	style.corner_radius_top_right   = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8

	var todo_panel := PanelContainer.new()
	todo_panel.add_theme_stylebox_override("panel", style)
	todo_panel.set_script(load("res://todo_window.gd"))
	todo_panel.visible = false
	todo_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	anchor.add_child(todo_panel)
	_todo_panel = todo_panel
	# 面板通过 ✕ 隐藏时，自动更新穿透区域
	_todo_panel.visibility_changed.connect(_update_mouse_region)

	_update_mouse_region()
	_reposition_todo_ui()


func _update_mouse_region() -> void:
	var ws: Vector2i = get_window().size
	var pos: Vector2 = global_position
	var wsxf: float = float(ws.x)
	var wsyf: float = float(ws.y)
	var rx0: float = pos.x - 650.0
	var ry0: float = pos.y - 350.0
	var rx1: float = pos.x + 650.0
	var ry1: float = pos.y + 350.0
	if rx0 < 0.0: rx0 = 0.0
	if ry0 < 0.0: ry0 = 0.0
	if rx1 > wsxf: rx1 = wsxf
	if ry1 > wsyf: ry1 = wsyf
	DisplayServer.window_set_mouse_passthrough(PackedVector2Array([
		Vector2(rx0, ry0), Vector2(rx1, ry0),
		Vector2(rx1, ry1), Vector2(rx0, ry1)
	]))





# ── 重新定位 Todo 按钮和面板（鸟鸟移动后调用）─────────────────
func _reposition_todo_ui() -> void:
	if not is_instance_valid(_todo_btn):
		return
	var pos := global_position
	# 按钮：鸟鸟正下方约 130px
	_todo_btn.position = pos + Vector2(-35, 130)

	if is_instance_valid(_todo_panel) and _todo_panel.visible:
		var screen_sz := DisplayServer.screen_get_size()
		# 起首用 size，未计算时用 custom_minimum_size
		var pw := _todo_panel.size.x if _todo_panel.size.x > 10 else _todo_panel.custom_minimum_size.x
		var ph := _todo_panel.size.y if _todo_panel.size.y > 10 else _todo_panel.custom_minimum_size.y
		# 优先放右边，放不下则左边
		if pos.x + 80 + pw + 10 <= screen_sz.x:
			_todo_panel.position = Vector2(pos.x + 80 + 10, pos.y - 160)
		else:
			_todo_panel.position = Vector2(pos.x - 140 - pw - 10, pos.y - 160)



func _on_todo_btn_pressed() -> void:
	if not is_instance_valid(_todo_panel):
		return
	_todo_panel.visible = not _todo_panel.visible
	_reposition_todo_ui()
	_update_mouse_region()




func _process(delta: float) -> void:
	# ── WebSocket 状态机 ────────────────────────────────────
	_ws.poll()
	var ws_state := _ws.get_ready_state()

	match ws_state:
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				var pkt  := _ws.get_packet()
				var text := pkt.get_string_from_utf8()
				_on_ws_message(text)

		WebSocketPeer.STATE_CLOSED:
			if not _should_reconnect:
				_should_reconnect = true
				_reconnect_timer  = 0.0
				print("[WS] 断开，将在 %.0f 秒后重连..." % _reconnect_delay)
				_update_status()

	# ── 重连定时 ────────────────────────────────────────────
	if _should_reconnect:
		_reconnect_timer += delta
		if _reconnect_timer >= _reconnect_delay:
			_should_reconnect = false
			_reconnect_delay  = min(_reconnect_delay * 2, 60.0)
			_connect_ws()

	# ── 全局活动检测：鼠标只要移动就重置入睡计时 ────────────
	var cur_mouse := DisplayServer.mouse_get_position()
	if cur_mouse != _last_mouse_pos:
		_last_mouse_pos = cur_mouse
		_idle_timer = 0.0
		if _state == State.SLEEPING:
			_wake_up()

	# ── 休眠计时（工作中不计入）────────────────────────────
	if _state != State.SLEEPING and _state != State.WORKING:
		_idle_timer += delta
		if _idle_timer >= SLEEP_INTERVAL:
			_idle_timer = 0.0
			print("[Pet] 进入休眠")
			_set_state(State.SLEEPING)

	# ── 久坐提醒（休眠中暂停）─────────────────────────────
	if _state != State.SLEEPING:
		_sedentary_timer += delta
		if _sedentary_timer >= SEDENTARY_INTERVAL:
			_sedentary_timer = 0.0
			print("[Pet] 久坐提醒（本地计时）")
			_trigger_side_animation()

	# ── 调试倒计时显示 ────────────────────────────────────
	var sleep_left: float = max(0.0, SLEEP_INTERVAL - _idle_timer)
	var sit_left: float   = max(0.0, SEDENTARY_INTERVAL - _sedentary_timer)
	_debug_label.text = "💤 入睡: %dm%02ds\n🪑 久坐: %dm%02ds\n状态: %s" % [
		int(sleep_left) / 60, int(sleep_left) % 60,
		int(sit_left)   / 60, int(sit_left)   % 60,
		State.keys()[_state]
	]


# ── WebSocket 连接 ────────────────────────────────────────
func _connect_ws() -> void:
	print("[WS] 正在连接 %s ..." % WS_URL)
	var err := _ws.connect_to_url(WS_URL)
	if err != OK:
		print("[WS] 连接失败，错误码：", err)
		_should_reconnect = true
		_reconnect_timer  = 0.0
	_update_status()


# ── 处理收到的消息 ────────────────────────────────────────
func _on_ws_message(raw: String) -> void:
	var msg = JSON.parse_string(raw)
	if msg == null:
		print("[WS] 无法解析 JSON")
		return

	var msg_type: String = msg.get("type", "")
	print("[WS] event=", msg.get("event", msg_type))

	# ── 收到 challenge，发送认证请求 ──────────────────────
	if msg_type == "event" and msg.get("event", "") == "connect.challenge":
		var nonce = msg.get("payload", {}).get("nonce", "")
		print("[WS] 收到 challenge nonce=", nonce, "，发送认证...")
		var auth_req := {
			"type": "req",
			"id": "bird-companion-001",
			"method": "connect",
			"params": {
				"minProtocol": 3,
				"maxProtocol": 3,
				"client": { "id": "cli", "version": "2026.3.2", "platform": "windows", "mode": "cli" },
				"role": "operator",
				"scopes": ["operator.read", "operator.write"],
				"auth": { "token": "lobster123" }
			}
		}
		_ws.send_text(JSON.stringify(auth_req))
		return

	# ── 收到认证响应 ──────────────────────────────────────
	if msg_type == "res":
		if msg.get("ok", false):
			print("[WS] 认证成功！")
			_reconnect_delay = 5.0
			_update_status()
		else:
			print("[WS] 认证失败：", msg)
		return

	# ── 中转服务器兼容（欢迎包）──────────────────────────
	if msg_type == "welcome":
		print("[WS] 已连接到中转服务器（旧模式）")
		_reconnect_delay = 5.0
		_update_status()
		return

	# ── 事件消息 ──────────────────────────────────────────
	if msg_type == "event":
		var evt: String = msg.get("event", "")
		var payload = msg.get("payload", {})
		_idle_timer = 0.0  # 任何事件都重置休眠计时

		if evt == "agent":
			match payload.get("stream", ""):
				"lifecycle":
					var phase = payload.get("data", {}).get("phase", "")
					match phase:
						"start":
							print("[Pet] AI 开始工作 → working")
							_wake_up_if_sleeping()
							_set_state(State.WORKING)
						"end":
							print("[Pet] AI 完成工作 → done")
							_set_state(State.DONE)
							await get_tree().create_timer(3.0).timeout
							_set_state(State.IDLE)
				"sedentary":
					print("[Pet] 久坐提醒")
					_sedentary_timer = 0.0
					_trigger_side_animation()
				"sleep":
					print("[Pet] 收到下班指令 → 休眠")
					_set_state(State.SLEEPING)
				"wake":
					print("[Pet] 收到唤醒指令")
					_wake_up()


# ── 切换宠物状态 ──────────────────────────────────────────
func _set_state(new_state: State) -> void:
	_state = new_state
	_update_status()
	var playback: AnimationNodeStateMachinePlayback = anim_tree["parameters/playback"]
	match new_state:
		State.IDLE:
			playback.travel("idle")
		State.WORKING:
			playback.travel("think")
		State.DONE:
			pass
		State.SLEEPING:
			playback.travel("sleep")


# ── 更新状态标签 ──────────────────────────────────────────
func _update_status() -> void:
	var ws_state := _ws.get_ready_state()
	if ws_state == WebSocketPeer.STATE_OPEN:
		status_label.text = "✅ 已连接"
	elif _should_reconnect:
		status_label.text = "🔄 重连中..."
	else:
		status_label.text = "⏳ 连接中..."


# ── 唤醒 ─────────────────────────────────────────────────
func _wake_up() -> void:
	if _state != State.SLEEPING:
		return
	print("[Pet] 唤醒！")
	_idle_timer = 0.0
	_set_state(State.IDLE)


func _wake_up_if_sleeping() -> void:
	if _state == State.SLEEPING:
		_wake_up()


# ── 触发歪头（点击交互）──────────────────────────────────
func _trigger_tilting() -> void:
	if _is_side_animating:
		return
	print("[Pet] 歪头！")
	var playback: AnimationNodeStateMachinePlayback = anim_tree["parameters/playback"]
	playback.travel("tiltinghead")


# ── 触发久坐提醒动画（turnleft → furry → turnleft 反向）──
func _trigger_side_animation() -> void:
	if _is_side_animating:
		return
	if _state == State.WORKING:
		return  # AI 工作中，不打断思考动画
	_is_side_animating = true
	print("[Pet] 侧面动画开始")

	# 1. 隐藏骨骼，显示帧动画
	body.visible = false
	skeleton.visible = false
	anim_tree.active = false
	animated_sprite.visible = true
	animated_sprite.speed_scale = 1.0

	# 2. 播放 turnleft
	animated_sprite.play("turnleft")
	await animated_sprite.animation_finished

	# 3. 播放 furry（播完整一遍后继续）
	animated_sprite.play("furry")
	await animated_sprite.animation_finished

	# 4. 从最后一帧倒放 turnleft，接回正面姿势
	animated_sprite.play("turnleft", -1.0, true)
	await animated_sprite.animation_finished

	# 5. 恢复骨骼动画
	animated_sprite.visible = false
	body.visible = true
	skeleton.visible = true
	anim_tree.active = true
	var playback: AnimationNodeStateMachinePlayback = anim_tree["parameters/playback"]
	playback.travel("idle")

	_is_side_animating = false
	print("[Pet] 侧面动画结束")


# ── 点击 / 拖拽（左键）───────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_idle_timer  = 0.0  # 点击重置入睡计时
			_drag_start  = DisplayServer.mouse_get_position()
			_is_dragging = false
		else:
			# 松开时：如果没拖动过 → 判断是否点到鸟身
			if not _is_dragging:
				var local_pos := body.to_local(event.position)
				if Geometry2D.is_point_in_polygon(local_pos - body.offset, body.polygon):
					if _state == State.SLEEPING:
						_wake_up()
					else:
						_trigger_tilting()
			_is_dragging = false

	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_idle_timer = 0.0  # 拖动也算活动
		var cur := DisplayServer.mouse_get_position()
		if not _is_dragging and (cur - _drag_start).length() > 5:
			_is_dragging = true
		if _is_dragging:
			# 全屏窗口：拖动 = 移动鸟鸟的 Node2D 位置
			position += event.relative
			_reposition_todo_ui()
			_update_mouse_region()
