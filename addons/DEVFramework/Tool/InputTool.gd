## 输入管理工具 — 输入模式切换 + 焦点组管理 + InputMap 操作 + 快捷键绑定
class_name InputTool

# ============================================================
# 常量
# ============================================================

const DEFAULT_SAVE_PATH := "user://input_settings.cfg"

## 输入模式
enum Mode {POINTER, NAVIGATION}

## 当前输入模式。
static var input_mode: Mode = Mode.POINTER

# ============================================================
# 输入模式切换
# ============================================================

## 切换输入模式。
static func set_input_mode(mode: Mode) -> void:
	input_mode = mode
	match mode:
		Mode.POINTER:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Mode.NAVIGATION:
			Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
			_ensure_focus()
	LogTool.log("输入", "输入模式更改:", Mode.keys()[mode])

## 根据 InputEvent 自动检测并切换输入模式。
static func detect_mode(event: InputEvent) -> void:
	var mode := input_mode
	if _is_pointer_event(event):
		mode = Mode.POINTER
	elif _is_navigation_event(event):
		mode = Mode.NAVIGATION
	else:
		return
	if mode != input_mode:
		set_input_mode(mode)

static func _is_pointer_event(event: InputEvent) -> bool:
	return event is InputEventMouseButton or event is InputEventMouseMotion \
		or event is InputEventScreenTouch or event is InputEventScreenDrag

static func _is_navigation_event(event: InputEvent) -> bool:
	if event is InputEventJoypadButton:
		return event.is_pressed()
	if event is InputEventJoypadMotion:
		return abs((event as InputEventJoypadMotion).axis_value) >= 0.5
	## 直接复用 _nav_dir，保持与 3D 导航的检测逻辑完全一致
	return _nav_dir(event) != Vector2.ZERO

# ============================================================
# 2D 焦点组 — 通过 focus_mode 控制控件是否参与 Godot 自动导航
# ============================================================

## 当前焦点组节点列表。
static var _focus_group: Array[Node] = []

## 当前导航焦点索引（仅 3D 用，2D 由 Godot 自动管理）。
static var _focus_index: int = -1

## 注册焦点组。2D 控件设为 FOCUS_ALL 启用导航，3D 节点交由 InputTool 手动管理。
static func register_focus_group(nodes: Array[Node], default_index: int = 0) -> void:
	_set_group_focus_mode(_focus_group, false)
	_focus_group = nodes.duplicate()
	_focus_index = default_index

	if nodes.is_empty():
		return

	if nodes[0] is Control:
		_set_group_focus_mode(nodes, true)
	elif not (nodes[0] is Node3D):
		push_warning("InputTool: 不支持的类型，需要 Control 或 Node3D")
		return

	LogTool.log("焦点导航", "注册焦点组 %s 节点数:%d" % ["2D" if nodes[0] is Control else "3D", nodes.size()])
	if input_mode == Mode.NAVIGATION:
		_ensure_focus()

## 清空焦点组，所有控件退出导航。
static func clear_focus_group() -> void:
	_set_group_focus_mode(_focus_group, false)
	_notify_focus_exit(_focus_group[_focus_index] if _focus_index >= 0 and _focus_index < _focus_group.size() else null)
	_focus_group.clear()
	_focus_index = -1
	LogTool.log("焦点导航", "焦点组已清空")

## 批量设置控件的 focus_mode 启用/禁用导航。
static func _set_group_focus_mode(nodes: Array[Node], enabled: bool) -> void:
	var mode := Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	for n in nodes:
		if is_instance_valid(n) and n is Control:
			n.focus_mode = mode

## 将鼠标移到指定节点的屏幕位置（2D Control 居中 / 3D Node3D 投影）。
static func warp_mouse_to_node(node: Node) -> void:
	if not is_instance_valid(node):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return
	if node is Control:
		var ctrl := node as Control
		var center: Vector2 = ctrl.global_position + ctrl.size * 0.5
		Input.warp_mouse(center)
	elif node is Node3D:
		var cam := tree.root.get_camera_3d()
		if not cam:
			return
		var screen_pos := cam.unproject_position((node as Node3D).global_position)
		Input.warp_mouse(screen_pos)

## 确保 NAVIGATION 模式下有焦点。
static func _ensure_focus() -> void:
	if input_mode != Mode.NAVIGATION or _focus_group.is_empty():
		return

	if _focus_group[0] is Node3D:
		_ensure_3d_focus()
	else:
		_ensure_2d_focus()

static func _ensure_2d_focus() -> void:
	var idx := _focus_index
	if idx < 0 or idx >= _focus_group.size():
		idx = 0
	if idx < _focus_group.size():
		var target := _focus_group[idx]
		if is_instance_valid(target) and target.is_visible_in_tree():
			target.grab_focus.call_deferred()

# ============================================================
# 3D 焦点导航 — 手动管理 3D 节点的焦点切换
# ============================================================

## 获取当前聚焦的 3D 节点。
static func get_3d_focus() -> Node:
	if _focus_index >= 0 and _focus_index < _focus_group.size() and _focus_group[0] is Node3D:
		return _focus_group[_focus_index]
	return null

## 统一处理输入。返回 true 表示事件已被消费（导航方向键/确认键）。
static func handle_input(event: InputEvent) -> bool:
	detect_mode(event)
	if input_mode == Mode.NAVIGATION and not _focus_group.is_empty():
		if _focus_group[0] is Node3D:
			return _handle_3d_navigation(event)
	return false

## 处理 3D 焦点导航和确认。返回 true 表示事件已被消费。
static func _handle_3d_navigation(event: InputEvent) -> bool:
	if _focus_group.is_empty() or not (_focus_group[0] is Node3D):
		return false

	if _focus_index < 0:
		_ensure_focus()
		if _focus_index < 0:
			return false

	var dir := _nav_dir(event)
	if dir != Vector2.ZERO:
		_move_3d(dir)
		return true

	if event.is_action_pressed("ui_accept"):
		_activate_3d()
		return true

	return false

static func _ensure_3d_focus() -> void:
	if _focus_index >= 0 and _focus_index < _focus_group.size():
		_set_focus(_focus_index)
	for i in _focus_group.size():
		var idx := i
		if _focus_index >= 0:
			idx = posmod(_focus_index + i, _focus_group.size())
		if _is_active(_focus_group[idx]):
			_set_focus(idx)
			return
	_focus_index = -1

static func _nav_dir(event: InputEvent) -> Vector2:
	if _match_dir(event, &"ui_up", KEY_W, KEY_UP): return Vector2.UP
	if _match_dir(event, &"ui_down", KEY_S, KEY_DOWN): return Vector2.DOWN
	if _match_dir(event, &"ui_left", KEY_A, KEY_LEFT): return Vector2.LEFT
	if _match_dir(event, &"ui_right", KEY_D, KEY_RIGHT): return Vector2.RIGHT
	return Vector2.ZERO

static func _match_dir(event: InputEvent, action: StringName, key1: Key, key2: Key) -> bool:
	if event.is_action_pressed(action):
		return true
	return event is InputEventKey and event.is_pressed() and not event.is_echo() \
		and (event.keycode == key1 or event.keycode == key2)

static func _set_focus(index: int) -> void:
	var prev := _focus_group[_focus_index] if _focus_index >= 0 and _focus_index < _focus_group.size() else null
	_focus_index = index
	var cur := _focus_group[_focus_index]
	_notify_focus_exit(prev)
	_notify_focus_enter(cur)

static func _move_3d(direction: Vector2) -> void:
	if _focus_index < 0:
		return

	var cur := _focus_group[_focus_index]
	var meta_key := "focus_up" if direction == Vector2.UP else "focus_down" if direction == Vector2.DOWN else "focus_left" if direction == Vector2.LEFT else "focus_right"
	if cur.has_meta(meta_key):
		var neighbor := cur.get_meta(meta_key) as Node
		var ni := _focus_group.find(neighbor)
		if ni >= 0 and _is_active(_focus_group[ni]):
			_set_focus(ni)
			return

	if cur is Node3D:
		var cam := (Engine.get_main_loop() as SceneTree).root.get_camera_3d()
		if not cam:
			return
		var cur_screen := cam.unproject_position((cur as Node3D).global_position)
		var best_score := INF
		var best_i := _focus_index

		for i in _focus_group.size():
			if i == _focus_index:
				continue
			var node := _focus_group[i]
			if not _is_active(node) or not node is Node3D:
				continue
			var delta: Vector2 = cam.unproject_position((node as Node3D).global_position) - cur_screen
			if not _in_direction(delta, direction):
				continue
			var dist: float = delta.length_squared()
			var cross_bias: float = abs(delta.y) * 3.0 if abs(direction.x) > 0.5 else abs(delta.x) * 3.0
			dist += cross_bias * cross_bias
			if dist < best_score:
				best_score = dist
				best_i = i

		if best_i != _focus_index:
			_set_focus(best_i)
			return

	var step := 1 if direction.y > 0.5 or direction.x > 0.5 else -1
	for _iter in _focus_group.size():
		var next := posmod(_focus_index + step, _focus_group.size())
		if _is_active(_focus_group[next]):
			_set_focus(next)
			return

static func _activate_3d() -> void:
	if _focus_index < 0 or _focus_index >= _focus_group.size():
		return
	var node := _focus_group[_focus_index]
	if not _is_active(node):
		return
	if node.has_method(&"_mouse_down"):
		node._mouse_down()
	if node.has_method(&"_mouse_up"):
		node._mouse_up()

# ============================================================
# 通用辅助
# ============================================================

## 检查节点是否可交互（有效、在场景树、可见、未禁用）。
static func _is_active(node: Node) -> bool:
	if not is_instance_valid(node) or not node.is_inside_tree() or not node.is_visible_in_tree():
		return false
	if node.has_method("is_disabled") and node.is_disabled():
		return false
	return true

static func _in_direction(delta: Vector2, direction: Vector2) -> bool:
	return not ((direction.x > 0.5 and delta.x <= 0) or
				(direction.x < -0.5 and delta.x >= 0) or
				(direction.y > 0.5 and delta.y <= 0) or
				(direction.y < -0.5 and delta.y >= 0))

## 触发节点焦点退出回调。优先 _focus_exit，回退 _mouse_exit。
static func _notify_focus_exit(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.has_method("_focus_exit"):
		node._focus_exit()
	elif node.has_method("_mouse_exit"):
		node._mouse_exit()

## 触发节点焦点进入回调。优先 _focus_enter，回退 _mouse_enter。
static func _notify_focus_enter(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.has_method("_focus_enter"):
		node._focus_enter()
	elif node.has_method("_mouse_enter"):
		node._mouse_enter()

# ============================================================
# InputMap 操作
# ============================================================

static func register_action(name: StringName, events: Array[InputEvent] = [], deadzone: float = 0.2) -> bool:
	if InputMap.has_action(name):
		return false
	InputMap.add_action(name, deadzone)
	for ev in events:
		InputMap.action_add_event(name, ev)
	return true

static func get_actions() -> Array[StringName]:
	return InputMap.get_actions()

static func get_events(action: StringName) -> Array[InputEvent]:
	if not InputMap.has_action(action):
		return []
	return InputMap.action_get_events(action)

static func rebind(action: StringName, events: Array[InputEvent]) -> void:
	if not InputMap.has_action(action):
		return
	_safe_erase(action)
	for ev in events:
		if not InputMap.action_has_event(action, ev):
			InputMap.action_add_event(action, ev)

static func add_event(action: StringName, event: InputEvent) -> void:
	if not InputMap.has_action(action) or InputMap.action_has_event(action, event):
		return
	InputMap.action_add_event(action, event)

static func remove_event(action: StringName, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		return
	for existing in InputMap.action_get_events(action):
		if existing.is_match(event, true):
			InputMap.action_erase_event(action, existing)
			return

static func clear_events(action: StringName) -> void:
	if InputMap.has_action(action):
		_safe_erase(action)

static func detect_conflict(event: InputEvent, exclude: StringName = &"") -> Array[StringName]:
	var conflicts: Array[StringName] = []
	for action in InputMap.get_actions():
		if action == exclude:
			continue
		for existing in InputMap.action_get_events(action):
			if existing.is_match(event, true):
				conflicts.append(action)
				break
	return conflicts

## 擦除 action 的所有事件并释放按键状态。
static func _safe_erase(action: StringName) -> void:
	if not InputMap.has_action(action):
		return
	InputMap.action_erase_events(action)
	if Input.is_action_pressed(action):
		Input.action_release(action)

# ============================================================
# 快捷键绑定
# ============================================================

static func bind_shortcut(button: BaseButton, action_name: StringName, key: Key, ctrl: bool = false, shift: bool = false) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
		var ev := InputEventKey.new()
		ev.keycode = key
		ev.ctrl_pressed = ctrl
		ev.shift_pressed = shift
		InputMap.action_add_event(action_name, ev)
	var shortcut := Shortcut.new()
	shortcut.events = InputMap.action_get_events(action_name)
	button.shortcut = shortcut

static func bind_shortcuts(bindings: Dictionary) -> void:
	for button: BaseButton in bindings:
		var cfg: Dictionary = bindings[button]
		bind_shortcut(button, cfg.get("action", &"") as StringName, cfg.get("key", KEY_NONE) as Key)

# ============================================================
# 持久化
# ============================================================

static func save(path: String = DEFAULT_SAVE_PATH) -> int:
	var config := ConfigFile.new()
	config.set_value("meta", "version", 2)
	for action in InputMap.get_actions():
		if String(action).begins_with("ui_"):
			continue
		var events: Array[Dictionary] = []
		for ev in InputMap.action_get_events(action):
			var d := _event_to_dict(ev)
			if not d.is_empty():
				events.append(d)
		var deadzone := InputMap.action_get_deadzone(action)
		config.set_value("input", action, {"deadzone": deadzone, "events": events})
	var err := config.save(path)
	if err != OK:
		push_error("InputTool: 保存失败 (%d) %s" % [err, path])
	return err

static func load(path: String = DEFAULT_SAVE_PATH) -> int:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return 0
	var ver: int = config.get_value("meta", "version", 0)
	if ver > 2:
		push_error("InputTool: 配置文件版本 (%d) 高于支持版本 (2)" % ver)
		return 0
	var count := 0
	for action in config.get_section_keys("input"):
		if not InputMap.has_action(action):
			continue
		var data = config.get_value("input", action)
		if not data is Dictionary:
			continue
		_safe_erase(action)
		for ev_dict in data.get("events", []):
			var ev := _dict_to_event(ev_dict as Dictionary)
			if ev != null:
				InputMap.action_add_event(action, ev)
				count += 1
	return count

static func reset_to_defaults() -> void:
	InputMap.load_from_project_settings()

# ============================================================
# 序列化
# ============================================================

static func _event_to_dict(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		return {type = "key", keycode = ev.keycode, physical_keycode = ev.physical_keycode,
				ctrl = ev.ctrl_pressed, shift = ev.shift_pressed, alt = ev.alt_pressed, meta = ev.meta_pressed}
	if ev is InputEventMouseButton:
		return {type = "mouse", button_index = ev.button_index, double_click = ev.double_click}
	if ev is InputEventJoypadButton:
		return {type = "joypad_button", button_index = ev.button_index}
	if ev is InputEventJoypadMotion:
		return {type = "joypad_motion", axis = ev.axis, axis_value = sign(ev.axis_value)}
	return {}

static func _dict_to_event(data: Dictionary) -> InputEvent:
	match data.get("type", ""):
		"key":
			var ev := InputEventKey.new()
			ev.physical_keycode = data.get("physical_keycode", KEY_NONE) as Key
			ev.keycode = data.get("keycode", KEY_NONE) as Key
			ev.ctrl_pressed = data.get("ctrl", false)
			ev.shift_pressed = data.get("shift", false)
			ev.alt_pressed = data.get("alt", false)
			ev.meta_pressed = data.get("meta", false)
			return ev if ev.keycode != KEY_NONE or ev.physical_keycode != KEY_NONE else null
		"mouse":
			var ev := InputEventMouseButton.new()
			ev.button_index = data.get("button_index", MOUSE_BUTTON_LEFT) as MouseButton
			ev.double_click = data.get("double_click", false)
			return ev
		"joypad_button":
			var ev := InputEventJoypadButton.new()
			ev.button_index = data.get("button_index", 0) as JoyButton
			return ev
		"joypad_motion":
			var ev := InputEventJoypadMotion.new()
			ev.axis = data.get("axis", 0) as JoyAxis
			ev.axis_value = data.get("axis_value", 0.0) as float
			return ev
	return null

# ============================================================
# 工厂方法
# ============================================================

static func key_event(keycode: Key, ctrl: bool = false, shift: bool = false, alt: bool = false, meta: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = keycode
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	e.alt_pressed = alt
	e.meta_pressed = meta
	return e

static func mouse_event(button_index: MouseButton) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button_index
	return e

static func create_shortcut(event: InputEvent) -> Shortcut:
	var s := Shortcut.new()
	s.events = [event]
	return s
