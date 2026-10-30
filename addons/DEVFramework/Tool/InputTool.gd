## 输入管理工具 — 设备模式切换（键鼠/手柄）+ 焦点组管理 + InputMap 操作 + 快捷键绑定
class_name InputTool

# ============================================================
# 按键图标 —— 来源与补充方式
# ============================================================
## 快捷键提示里的按键一律用图标，不用文字（见 TipTool._format / _normalize）：
## 图标写在 Assets/Translation/tip.csv 对应事件行里，形如
##   KEY_ENTER,[img=48x48]res://Assets/Texture/Keycap/keyboard_mouse/keyboard_enter.png[/img],...
## 键名规则见 _event_key：一律取枚举名，手柄 JOY_BUTTON_*、摇杆 JOY_AXIS_*、鼠标 MOUSE_BUTTON_*、键盘 KEY_*。
## 组合键不必单独配行，_key_text 会把修饰键和主键拆开再拼（Shift+Backspace → 两个图标）。
## 图标画布 Kenney 64、Xelu 100（内容均占约 75%~85%），故按 [img=48x48] 引用，视觉内容约 36px ≈ 提示条 38px 中文文字高度。
##
## 项目内图标目录：res://Assets/Texture/Keycap/（CC0）
##   xbox/           手柄键位、摇杆轴、扳机、背键          Kenney Input Prompts
##   keyboard_mouse/ 键盘键、鼠标左右中键                  Xelu Free Key Prompts（实心字，小尺寸可读）
##   keyboard_mouse/ 滚轮、侧键                            Kenney Input Prompts
##   touch/          触摸手势                              Kenney Input Prompts
## JOY_BUTTON_* / JOY_AXIS_* / MOUSE_BUTTON_* / KEY_* 已全部映射到 tip.csv。
##
## 需要整套或补别的平台时去这些地方取（均可免费商用）：
##   Kenney Input Prompts  https://kenney.nl/assets/input-prompts       全套 3000+，含 PS/Switch/Steam Deck/Quest/触屏，CC0
##   Xelu Free Key Prompts https://thoseawesomeguys.com/prompts/        键盘/手柄扁平风，键位最全，CC0
##   Game-icons.net        https://game-icons.net/                      通用图标（耳机、麦克风等），CC BY 3.0
##   Kenney Game Icons     https://kenney.nl/assets/game-icons          设备/功能类图标，CC0
## 步骤：图片放入 Assets/Texture/Keycap/ → tip.csv 加 [img=宽x高]res://...[/img] → 重新导入 tip.csv 即生效。

# ============================================================
# 常量
# ============================================================

const DEFAULT_SAVE_PATH := "user://input_settings.cfg"

## 操作设备模式：POINTER = 键鼠指针，NAVIGATION = 手柄/方向键导航
enum DeviceMode {POINTER, NAVIGATION}

## 最近使用的具体输入设备：提示条只显示当前设备用得到的键
enum InputDevice {MOUSE, KEYBOARD, GAMEPAD}

## 当前设备模式（detect_mode 自动切换；控制光标锁定与焦点导航）
static var device_mode: DeviceMode = DeviceMode.POINTER
## 最近一次输入事件所属设备（提示文案据此过滤按键，不再把三套设备全列出来）
static var last_device: InputDevice = InputDevice.MOUSE

static func is_navigation() -> bool:
	return device_mode == DeviceMode.NAVIGATION

# ============================================================
# 设备模式切换
# ============================================================

## 切换设备模式。
static func set_device_mode(mode: DeviceMode) -> void:
	device_mode = mode
	match mode:
		DeviceMode.POINTER:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		DeviceMode.NAVIGATION:
			Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
			_ensure_focus()
	LogTool.log("输入", "操作模式更改:", DeviceMode.keys()[mode])

## 根据 InputEvent 自动检测并切换设备模式。
static func detect_mode(event: InputEvent) -> void:
	track_device(event)
	var mode := device_mode
	if _is_pointer_event(event):
		mode = DeviceMode.POINTER
	elif _is_navigation_event(event):
		mode = DeviceMode.NAVIGATION
	else:
		return
	if mode != device_mode:
		set_device_mode(mode)

## 记录最近输入设备（只影响提示文案，不改设备模式）
static func track_device(event: InputEvent) -> void:
	var device := _device_of(event)
	if device >= 0:
		last_device = device

## 事件所属的具体设备（未知事件返回 -1）
static func _device_of(event: InputEvent) -> int:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return InputDevice.GAMEPAD
	if event is InputEventMouseButton or event is InputEventMouseMotion \
			or event is InputEventScreenTouch or event is InputEventScreenDrag:
		return InputDevice.MOUSE
	if event is InputEventKey:
		return InputDevice.KEYBOARD
	return -1

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
## 注册完直接落焦点（NAVIGATION 下）——调用方不必再自己补 `_ensure_focus`。
static func register_focus_group(nodes: Array[Node], default_index: int = 0) -> void:
	_set_group_focus_mode(_focus_group, false)
	## 换组前先通知旧焦点退出，否则 3D 高亮残留在上一个面板的节点上
	_notify_focus_exit(_focused())
	## 空组等价于清空：别留下 _focus_index 指向不存在元素的半状态
	if nodes.is_empty():
		_focus_group.clear()
		_focus_index = -1
		return
	_focus_group = nodes.duplicate()
	_focus_index = default_index

	if nodes[0] is Control:
		_set_group_focus_mode(nodes, true)
	elif not (nodes[0] is Node3D):
		push_warning("InputTool: 不支持的类型，需要 Control 或 Node3D")
		return

	LogTool.log("焦点导航", "注册焦点组 %s 节点数:%d" % ["2D" if nodes[0] is Control else "3D", nodes.size()])
	if device_mode == DeviceMode.NAVIGATION:
		_ensure_focus()

## 清空焦点组，所有控件退出导航。
static func clear_focus_group() -> void:
	_set_group_focus_mode(_focus_group, false)
	_notify_focus_exit(_focused())
	_focus_group.clear()
	_focus_index = -1
	LogTool.log("焦点导航", "焦点组已清空")

## 当前焦点节点（越界/空组返回 null；可能已释放，用前按需判 is_instance_valid）。
## 参数与返回值不加类型标注，理由同 `_is_active`。
static func _focused():
	if _focus_index < 0 or _focus_index >= _focus_group.size():
		return null
	return _focus_group[_focus_index]

## 当前焦点组是否就是这批节点（给"只想收自己那份"的调用方用，如 EquipOptionMenu）
static func is_focus_group(nodes: Array) -> bool:
	return _focus_group == nodes

## 批量设置控件的 focus_mode 启用/禁用导航。
static func _set_group_focus_mode(nodes: Array[Node], enabled: bool) -> void:
	var mode := Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	for n in nodes:
		if is_instance_valid(n) and n is Control:
			n.focus_mode = mode

## 剔除焦点组里已释放的节点（注册方被销毁时未必来得及注销）。
## ⚠️ 已释放实例一旦作为参数传给带 `Node` 标注的函数，Godot 在**传参阶段**就报
## "previously freed is not a subclass of Node"，调试模式下当场中断主循环（表现为整局卡死）。
static func _prune_focus_group() -> void:
	if _focus_group.is_empty():
		return
	## 原地压缩：导航每次按键都会走到这里，不必每次新建数组；无失效项时不写、直接返回
	var write := 0
	var new_index := -1
	for read in _focus_group.size():
		var node = _focus_group[read]
		if not is_instance_valid(node):
			continue
		if read == _focus_index:
			new_index = write
		if write != read:
			_focus_group[write] = node
		write += 1
	if write == _focus_group.size():
		return
	if write == 0:
		_focus_group.clear()
		_focus_index = -1
		return
	_focus_group.resize(write)
	_focus_index = new_index if new_index >= 0 else mini(_focus_index, write - 1)

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
		var cam := CameraTool.get_camera()
		if not cam:
			return
		var screen_pos := cam.unproject_position((node as Node3D).global_position)
		Input.warp_mouse(screen_pos)

## 确保 NAVIGATION 模式下有焦点。
static func _ensure_focus() -> void:
	_prune_focus_group()
	if device_mode != DeviceMode.NAVIGATION or _focus_group.is_empty():
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

## 获取当前聚焦的 3D 节点（已释放/失效时返回 null）。
static func get_3d_focus() -> Node:
	var node = _focused()
	return node if is_instance_valid(node) and node is Node3D else null

## 统一处理输入。返回 true 表示事件已被消费（导航方向键/确认键）。
static func handle_input(event: InputEvent) -> bool:
	detect_mode(event)
	if device_mode == DeviceMode.NAVIGATION and not _focus_group.is_empty():
		if _focus_group[0] is Node3D:
			return _handle_3d_navigation(event)
	return false

## 处理 3D 焦点导航和确认。返回 true 表示事件已被消费。
static func _handle_3d_navigation(event: InputEvent) -> bool:
	_prune_focus_group()
	if _focus_group.is_empty() or not (_focus_group[0] is Node3D):
		return false

	if _focus_index < 0:
		_ensure_focus()
		if _focus_index < 0:
			return false
	## ⚠️ 当前焦点节点可能已被释放（注册方销毁时没来得及清）⇒ 重新挑一个有效的，
	## 否则下面的 _move_3d / _activate_3d 会拿到已释放实例报错
	if not _is_active(_focus_group[_focus_index]):
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
	## 当前焦点仍可用就直接启用它（否则会沿着组再 _set_focus 一次，enter 通知发两遍）
	if _is_active(_focused()):
		_set_focus(_focus_index)
		return
	for i in _focus_group.size():
		var idx := i
		if _focus_index >= 0:
			idx = posmod(_focus_index + i, _focus_group.size())
		if _is_active(_focus_group[idx]):
			_set_focus(idx)
			return
	_focus_index = -1

## 方向判定：先认 InputMap 动作，再兜底硬编码 WASD / 方向键
## （ui_* 只绑了手柄或没绑键盘时，键盘导航仍可用）
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
	if index < 0 or index >= _focus_group.size():
		return
	var prev = _focused()
	var target = _focus_group[index]
	_focus_index = index
	## 焦点没变时只补 enter（重新进入导航态要恢复高亮），不能先发一次 exit
	if not is_same(prev, target):
		_notify_focus_exit(prev)
	_notify_focus_enter(target)

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
		var cam := CameraTool.get_camera()
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
## 参数**不加类型标注**：已释放实例可以传进来由 `is_instance_valid` 兜住，
## 标成 `Node` 反而会在传参阶段抛 "previously freed"（见 `_prune_focus_group`）。
static func _is_active(node) -> bool:
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
## 参数不加类型标注，理由同 `_is_active`。
static func _notify_focus_exit(node) -> void:
	if not is_instance_valid(node):
		return
	if node.has_method("_focus_exit"):
		node._focus_exit()
	elif node.has_method("_mouse_exit"):
		node._mouse_exit()

## 触发节点焦点进入回调。优先 _focus_enter，回退 _mouse_enter。
static func _notify_focus_enter(node) -> void:
	if not is_instance_valid(node):
		return
	if node.has_method("_focus_enter"):
		node._focus_enter()
	elif node.has_method("_mouse_enter"):
		node._mouse_enter()

# ============================================================
# InputMap 操作
# ============================================================

## 键位版本：任何改键后自增，提示层据此判断文案要不要重画
static var binding_version := 0

static func register_action(name: StringName, events: Array[InputEvent] = [], deadzone: float = 0.2) -> bool:
	if InputMap.has_action(name):
		return false
	InputMap.add_action(name, deadzone)
	for ev in events:
		InputMap.action_add_event(name, ev)
	binding_version += 1
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
	binding_version += 1

static func add_event(action: StringName, event: InputEvent) -> void:
	if not InputMap.has_action(action) or InputMap.action_has_event(action, event):
		return
	InputMap.action_add_event(action, event)
	binding_version += 1

static func remove_event(action: StringName, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		return
	for existing in InputMap.action_get_events(action):
		if existing.is_match(event, true):
			InputMap.action_erase_event(action, existing)
			binding_version += 1
			return

static func clear_events(action: StringName) -> void:
	if InputMap.has_action(action):
		_safe_erase(action)
		binding_version += 1

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

static func bind_shortcut(button: BaseButton, action: StringName, key: Key, ctrl: bool = false, shift: bool = false) -> void:
	if not InputMap.has_action(action):
		register_action(action, [key_event(key, ctrl, shift)])
	var shortcut := Shortcut.new()
	shortcut.events = InputMap.action_get_events(action)
	button.shortcut = shortcut

## 批量绑定：{Button: {action, key, ctrl?, shift?}}
static func bind_shortcuts(bindings: Dictionary) -> void:
	for button: BaseButton in bindings:
		var cfg: Dictionary = bindings[button]
		bind_shortcut(button, cfg.get("action", &"") as StringName, cfg.get("key", KEY_NONE) as Key,
			cfg.get("ctrl", false), cfg.get("shift", false))

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

static func joy_event(button_index: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button_index
	return e

static func axis_event(axis: JoyAxis, value: float = 1.0) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	return e

static func create_shortcut(event: InputEvent) -> Shortcut:
	var s := Shortcut.new()
	s.events = [event]
	return s

# ============================================================
# 按键提示 — 文案走 csv：手柄/鼠标用枚举名反查，键盘直接用 as_text
# ============================================================

## 手柄按钮（值与 JoyButton 对齐）。Godot 没有枚举名反射，但 enum 在脚本里就是
## Dictionary，find_key() 能直接反查名字，所以不用再维护 value → key 的映射表。
## 新增手柄键：这里加一行，csv 加一行 JOY_BUTTON_<名字> 即生效。
enum JoyKey {
	A = 0, B = 1, X = 2, Y = 3, BACK = 4, GUIDE = 5, START = 6,
	LEFT_STICK = 7, RIGHT_STICK = 8, LEFT_SHOULDER = 9, RIGHT_SHOULDER = 10,
	DPAD_UP = 11, DPAD_DOWN = 12, DPAD_LEFT = 13, DPAD_RIGHT = 14,
	MISC1 = 15, PADDLE1 = 16, PADDLE2 = 17, PADDLE3 = 18, PADDLE4 = 19, TOUCHPAD = 20,
}

## 摇杆/扳机轴（值与 JoyAxis 对齐）
enum JoyAxis { LEFT_X = 0, LEFT_Y = 1, RIGHT_X = 2, RIGHT_Y = 3, TRIGGER_LEFT = 4, TRIGGER_RIGHT = 5 }

## 鼠标按钮（值与 MouseButton 对齐）
enum MouseKey {
	LEFT = 1, RIGHT = 2, MIDDLE = 3, WHEEL_UP = 4, WHEEL_DOWN = 5,
	WHEEL_LEFT = 6, WHEEL_RIGHT = 7, XBUTTON1 = 8, XBUTTON2 = 9,
}

## 按键/动作 → 文本（该设备无绑定时返回 ""）
## device 指定设备（[enum InputDevice]），-1 表示按当前模式取（键鼠共用键盘）
static func input_text(target: Variant, device := -1) -> String:
	if target is InputEvent:
		return _event_text(target, device)
	if target is StringName or target is String:
		## 动作常绑多个备选键（menu 同时有 B 和 Start），提示只显示首个能渲染的主键
		for event in get_events(StringName(target)):
			var text := _event_text(event, device)
			if text:
				return text
	return ""

## 事件 → 文本；csv 没配就回退系统键名。
## 摇杆/扳机无图标时返回空，不上长英文（as_text 形如 "Joypad Motion ... Value 1.00"）
static func _event_text(event: InputEvent, device := -1) -> String:
	if not _match_device(event, device):
		return ""
	if event is InputEventKey:
		return _key_text(event)
	return _lookup(_event_key(event), "" if event is InputEventJoypadMotion else event.as_text())

## 键盘：修饰键在前、主键在后，各自取图标/键名，用 + 连接（组合键无需在 csv 单独配行）
static func _key_text(event: InputEventKey) -> String:
	var parts := PackedStringArray()
	for pair in [[event.ctrl_pressed, KEY_CTRL], [event.shift_pressed, KEY_SHIFT],
			[event.alt_pressed, KEY_ALT], [event.meta_pressed, KEY_META]]:
		if pair[0]:
			parts.append(_key_cell(pair[1]))
	## 绑定可能只填了 physical_keycode（编辑器默认），此时 keycode 为 0
	parts.append(_key_cell(event.keycode if event.keycode != 0 else event.physical_keycode))
	return "+".join(parts)

static func _key_cell(keycode: int) -> String:
	return _lookup(_event_key(key_event(keycode)), OS.get_keycode_string(keycode))

## 固定 key（与语言无关）：手柄/鼠标/键盘统一取枚举名，避免 as_text 随语言或引擎版本变化
static func _event_key(event: InputEvent) -> String:
	var prefix := ""
	var name: Variant
	if event is InputEventJoypadButton:
		prefix = "JOY_BUTTON_"
		name = JoyKey.find_key(event.button_index)
	elif event is InputEventJoypadMotion:
		prefix = "JOY_AXIS_"
		name = JoyAxis.find_key(event.axis)
	elif event is InputEventScreenTouch:
		return "MOUSE_BUTTON_LEFT"
	elif event is InputEventMouseButton:
		prefix = "MOUSE_BUTTON_"
		name = MouseKey.find_key(event.button_index)
	elif event is InputEventKey:
		## Key 是原生枚举无法反射，用系统键名推导出与枚举名同形的 key（"Kp Enter" → KEY_KP_ENTER）
		var kb := OS.get_keycode_string(event.keycode)
		return "KEY_" + kb.to_upper().replace(" ", "_") if not kb.is_empty() else ""
	else:
		return ""
	return prefix + str(name) if name != null else ""

## 事件是否符合设备：device >= 0 时只认该设备；-1 时按模式（鼠标/触摸归指针，
## 手柄归导航，键盘两种共用）
static func _match_device(event: InputEvent, device := -1) -> bool:
	if device >= 0:
		return _device_of(event) == device
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return is_navigation()
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		return not is_navigation()
	return event is InputEventKey

## csv 有配置就用（多为图标），否则回退
static func _lookup(key: String, fallback: String = "") -> String:
	if key.is_empty():
		return fallback
	var text := str(TranslationServer.translate(key))
	return fallback if (text == key or text.is_empty()) else text
