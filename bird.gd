extends Node2D

# ── 节点引用 ──────────────────────────────────────────────
@onready var anim_tree: AnimationTree = $AnimationTree
@onready var body: Polygon2D = $body
@onready var status_label: Label = $StatusLabel
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var skeleton: Skeleton2D = $Skeleton2D

var _debug_label: Label
var _todo_panel:     Window
var _todo_btn:       Button
var _calendar_panel: Window
var _calendar_btn:   Button
var _todo_positioned     := false
var _calendar_positioned := false

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
const SEDENTARY_INTERVAL := 0.15 * 60.0  # DEBUG: 9秒（テスト用）
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
	get_window().gui_embed_subwindows = false
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
	# ── CanvasLayer 只用于放置切换按钮（靠近鸟鸟）──────────
	var canvas := CanvasLayer.new()
	canvas.layer = 10
	add_child(canvas)

	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(anchor)

	# ── 切换按钮 ─────────────────────────────────────────
	_todo_btn = Button.new()
	_todo_btn.text = "📝 Todo"
	_todo_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_todo_btn.flat = true
	_todo_btn.modulate = Color(1, 1, 1, 0.75)
	_todo_btn.pressed.connect(_on_todo_btn_pressed)
	anchor.add_child(_todo_btn)

	_calendar_btn = Button.new()
	_calendar_btn.text = "📅 日历"
	_calendar_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_calendar_btn.flat = true
	_calendar_btn.modulate = Color(1, 1, 1, 0.75)
	_calendar_btn.pressed.connect(_on_calendar_btn_pressed)
	anchor.add_child(_calendar_btn)

	# ── Todo 独立 Window ──────────────────────────────────
	var todo_win := Window.new()
	todo_win.set_script(load("res://todo_window.gd"))
	todo_win.visible = false
	add_child(todo_win)
	_todo_panel = todo_win
	_todo_panel.request_ws_send.connect(_on_todo_ws_send)
	_todo_panel.close_requested.connect(_todo_panel.hide)

	# ── Calendar 独立 Window ──────────────────────────────
	var cal_win := Window.new()
	cal_win.set_script(load("res://calendar_window.gd"))
	cal_win.visible = false
	add_child(cal_win)
	_calendar_panel = cal_win
	_calendar_panel.request_ws_send.connect(_on_todo_ws_send)
	_calendar_panel.close_requested.connect(_calendar_panel.hide)

	_update_mouse_region()
	_reposition_todo_ui()


func _update_mouse_region() -> void:
	# 覆盖鸟本体 + 头顶标签（offset_left=-120, offset_top=-160）+ 按钮区
	var bird_rect := Rect2(global_position + Vector2(-125, -165), Vector2(250, 335))
	var btn_rect  := Rect2(global_position + Vector2(-90,  120),  Vector2(200, 40))
	var area := bird_rect.merge(btn_rect)
	var pts := PackedVector2Array([
		area.position,
		Vector2(area.end.x, area.position.y),
		area.end,
		Vector2(area.position.x, area.end.y)
	])
	DisplayServer.window_set_mouse_passthrough(pts)





# ── 重新定位 Todo 按钮和面板（鸟鸟移动后调用）─────────────────
func _reposition_todo_ui() -> void:
	if not is_instance_valid(_todo_btn):
		return
	var pos := global_position
	# 只有按钮跟着鸟鸟移动，面板位置完全独立
	_todo_btn.position     = pos + Vector2(-70, 130)
	if is_instance_valid(_calendar_btn):
		_calendar_btn.position = pos + Vector2(10, 130)



func _on_todo_btn_pressed() -> void:
	if not is_instance_valid(_todo_panel):
		return
	if _todo_panel.visible:
		_todo_panel.hide()
	else:
		if not _todo_positioned:
			_todo_positioned = true
			var gp := Vector2i(int(global_position.x), int(global_position.y))
			var bird_screen_pos := get_window().position + gp
			_todo_panel.position = bird_screen_pos + Vector2i(-320, -200)
		_todo_panel.show()


func _on_calendar_btn_pressed() -> void:
	if not is_instance_valid(_calendar_panel):
		return
	if _calendar_panel.visible:
		_calendar_panel.hide()
	else:
		if not _calendar_positioned:
			_calendar_positioned = true
			var gp := Vector2i(int(global_position.x), int(global_position.y))
			var bird_screen_pos := get_window().position + gp
			_calendar_panel.position = bird_screen_pos + Vector2i(-320, -300)
		_calendar_panel.show()




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

	# ── 每帧更新鼠标穿透区域（鸟鸟可能被拖动）────────────
	if _is_dragging:
		_update_mouse_region()
	var sleep_left: float = max(0.0, SLEEP_INTERVAL - _idle_timer)
	var sit_left: float   = max(0.0, SEDENTARY_INTERVAL - _sedentary_timer)
	_debug_label.text = "💤 入睡: %dm%02ds\n🪑 久坐: %dm%02ds\n状态: %s" % [
		int(sleep_left) / 60, int(sleep_left) % 60,
		int(sit_left)   / 60, int(sit_left)   % 60,
		State.keys()[_state]
	]


# ── 代 Todo 面板发送 WS 消息 ──────────────────────────────
func _on_todo_ws_send(method: String, params: Dictionary) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("[WS] 未连接，无法发送 Todo 同步请求")
		return
	var req := {
		"type": "req",
		"id": "todo-sync-%d" % Time.get_unix_time_from_system(),
		"method": method,
		"params": params
	}
	_ws.send_text(JSON.stringify(req))
	print("[WS] 发送 Todo 请求 method=", method)


# ── 拉取最后一条 chat 历史（同步完成后取 AI 回复）─────────
func _fetch_chat_history() -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var req := {
		"type": "req",
		"id": "todo-history",
		"method": "chat.history",
		"params": {
			"sessionKey": "agent:main:main",
			"limit": 1
		}
	}
	_ws.send_text(JSON.stringify(req))
	print("[WS] 拉取 chat.history")


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
		var res_id: String = msg.get("id", "")
		# chat.history 响应 → 取最后一条 AI 回复（必须在 todo- 前检查）
		if res_id == "todo-history":
			if msg.get("ok", false):
				var messages: Array = msg.get("payload", {}).get("messages", [])
				print("[WS] chat.history 收到 %d 条" % messages.size())
				for i in range(messages.size() - 1, -1, -1):
					var m = messages[i]
					var role: String = m.get("role", "")
					if role == "assistant":
						var raw_content = m.get("content", "")
						var content: String = ""
						if raw_content is String:
							content = raw_content
						elif raw_content is Array:
							# content blocks 格式：[{"type":"text","text":"..."}]
							for block in raw_content:
								if block.get("type", "") == "text":
									content += block.get("text", "")
						print("[WS] AI 回复内容: ", content.substr(0, 200))
						if is_instance_valid(_todo_panel):
							_todo_panel.on_chat_response(content)
						if is_instance_valid(_calendar_panel):
							_calendar_panel.on_chat_response(content)
						break
				await get_tree().create_timer(3.0).timeout
				_set_state(State.IDLE)
			else:
				print("[WS] chat.history 失败：", msg.get("error", {}))
				if is_instance_valid(_todo_panel):
					_todo_panel._set_sync_status("❌ 拉取历史失败")
					_todo_panel._waiting_for_sync_response = false
				await get_tree().create_timer(3.0).timeout
				_set_state(State.IDLE)
			return
		# todo 同步的其他响应
		if res_id.begins_with("todo-"):
			if not msg.get("ok", false):
				print("[Todo] 请求失败：", msg.get("error", {}))
				if is_instance_valid(_todo_panel):
					_todo_panel._set_sync_status("❌ 请求失败")
					_todo_panel._waiting_for_sync_response = false
			return
		# calendar 同步响应
		if res_id.begins_with("calendar-"):
			if not msg.get("ok", false):
				print("[Calendar] 请求失败：", msg.get("error", {}))
				if is_instance_valid(_calendar_panel):
					_calendar_panel._set_sync_status("❌ 请求失败")
					_calendar_panel._waiting_for_sync_response = false
			return
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
			var stream: String = payload.get("stream", "")
			match stream:
				"lifecycle":
					var phase = payload.get("data", {}).get("phase", "")
					var run_id: String = payload.get("runId", "")
					match phase:
						"start":
							print("[Pet] AI 开始工作 → working")
							_wake_up_if_sleeping()
							_set_state(State.WORKING)
						"end":
							print("[Pet] AI 完成工作 → done")
							_set_state(State.DONE)
							# 如果是 todo 或 calendar 同步触发的 run，拉取回复内容
							var is_sync_run: bool = run_id.begins_with("todo-sync-") or run_id.begins_with("calendar-sync-")
							var todo_waiting: bool = is_instance_valid(_todo_panel) and _todo_panel._waiting_for_sync_response
							var cal_waiting: bool = is_instance_valid(_calendar_panel) and _calendar_panel._waiting_for_sync_response
							var panel_waiting: bool = todo_waiting or cal_waiting
							if is_sync_run and panel_waiting:
								_fetch_chat_history()
							else:
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

		# ── chat 响应转发给 todo 面板 ─────────────────────
		elif evt == "chat":
			print("[WS CHAT RAW] ", msg)
			var text: String = payload.get("data", {}).get("text", "")
			if text.is_empty():
				text = payload.get("data", {}).get("delta", "")
			if not text.is_empty() and is_instance_valid(_todo_panel):
				_todo_panel.on_chat_response(text)


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
	print("[Pet] 播放 turnleft，等待完成...")
	await animated_sprite.animation_finished
	print("[Pet] turnleft 完成")

	# 3. 播放 furry（播完整一遍后继续）
	animated_sprite.play("furry")
	print("[Pet] 播放 furry，等待完成...")
	await animated_sprite.animation_finished
	print("[Pet] furry 完成")

	# 4. 从最后一帧倒放 turnleft，接回正面姿势
	animated_sprite.play("turnleft", -1.0, true)
	print("[Pet] 倒放 turnleft，等待完成...")
	await animated_sprite.animation_finished
	print("[Pet] 倒放完成")

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
