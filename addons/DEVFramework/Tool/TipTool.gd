class_name TipTool

## 操作提示条：把「按键 + 文案 key」渲染成 "[图标] 文案 · [图标] 文案"。
## 多来源共用一个栈：priority 大者优先，同级后进优先；source 失效（释放/隐藏）自动收起。
## 宿主只需 attach() 一次渲染目标，其余地方直接 show_tip / hide_tip。

## 渲染目标与显隐动画（宿主注入）
static var label: RichTextLabel
static var tween: TweenAnimation
## 悬停提示延迟（秒）：避免鼠标扫过一排按钮时提示连续闪烁
static var hover_delay := 0.12
## 收起延迟（秒）：与 hover_delay 成对，鼠标在按钮间移动时不出现空窗
static var hide_delay := 0.06
## 一行最多显示的条数，超出丢弃
const MAX_ITEMS := 4

## 提示栈 {source, entries, priority}，数组顺序即出现顺序（同级后进优先）
static var _stack: Array = []
## 延迟待显示 {source -> {entries, priority, at}}
static var _delayed := {}
## 延迟待收起 {source -> at}
static var _hiding := {}
static var _tree: SceneTree
static var _device := -1
static var _last_device := -1
static var _locale := ""
static var _binding := -1
static var _shown := false
static var _dirty := false

## 在宿主 _ready 里绑定一次；label 需已入树。传 null 解除绑定
static func attach(target: RichTextLabel, target_tween: TweenAnimation = null) -> void:
	_unbind()
	label = target
	tween = target_tween
	_stack.clear()
	_delayed.clear()
	_hiding.clear()
	_device = -1
	_last_device = -1
	_locale = ""
	_binding = -1
	_shown = false
	if _can_show():
		_tree = label.get_tree()
		_tree.process_frame.connect(_tick)
	_render()

## 显示提示。entries 三种写法：
##   &"key"                确认键 + 文案（多数场景）
##   [[keys, &"key"], ...] 自定义按键
##   [&"key", &"key2"]     多个确认键文案
## delay > 0 时延迟显示，供悬停使用
static func show_tip(entries: Variant, source: Object = null, priority := 0, delay := 0.0) -> void:
	if not _can_show():
		return
	var items := _normalize(entries)
	if items.is_empty():
		return
	if delay > 0.0 and source != null:
		_delayed[source] = {
			entries = items,
			priority = priority,
			at = Time.get_ticks_msec() + int(delay * 1000.0),
		}
		return
	_push(source, items, priority)

## 收起指定来源的提示（含尚未到期的延迟项）；delay > 0 时延迟收起，供悬停使用
static func hide_tip(source: Object, delay := 0.0) -> void:
	_delayed.erase(source)
	if delay <= 0.0:
		_hiding.erase(source)
		_remove(source)
	elif _find(source) >= 0:
		_hiding[source] = Time.get_ticks_msec() + int(delay * 1000.0)

static func hide_all() -> void:
	_stack.clear()
	_delayed.clear()
	_hiding.clear()
	_dirty = true

## 确认键：只取当前设备那一个（鼠标左键 / 键盘 accept / 手柄 accept，跟随改键）
static func confirm_keys() -> Array:
	match InputTool.last_device:
		InputTool.InputDevice.MOUSE:
			return [InputTool.mouse_event(MOUSE_BUTTON_LEFT)]
		InputTool.InputDevice.GAMEPAD:
			for event in InputTool.get_events(&"ui_accept"):
				if event is InputEventJoypadButton:
					return [event]
			return [InputTool.joy_event(JOY_BUTTON_A)]
	for event in InputTool.get_events(&"ui_accept"):
		if event is InputEventKey:
			return [event]
	return [InputTool.key_event(KEY_ENTER)]

## 统一成 [[按键, 文案key], ...] 并限制条数
## 按键写空数组表示「确认键」，渲染时再取当前绑定，改键后自动跟随
## 丢弃没有合法文案 key 的条目（如空 click_tip），否则只会渲染出孤立按键图标
static func _normalize(entries: Variant) -> Array:
	var items := []
	if entries is StringName or entries is String:
		items.append([[], StringName(entries)])
	elif entries is Array:
		for entry in entries:
			if entry is Array:
				items.append(entry)
			elif entry is StringName or entry is String:
				items.append([[], StringName(entry)])
	items = items.filter(func(item: Variant) -> bool:
		if not (item is Array) or item.size() < 2:
			return false
		var key: Variant = item[1]
		return (key is StringName or key is String) and not str(key).is_empty()
	)
	return items.slice(0, MAX_ITEMS)

## 写入或覆盖某个来源的提示
static func _push(source: Object, items: Array, priority: int) -> void:
	_delayed.erase(source)
	_hiding.erase(source)
	for item in _stack:
		if item.source == source:
			item.entries = items
			item.priority = priority
			_dirty = true
			return
	_stack.append({source = source, entries = items, priority = priority})
	_dirty = true

## 每帧：到期显示/收起；栈、设备、语言、键位任一变化时才重渲染
static func _tick() -> void:
	if not _can_show():
		_unbind()
		return
	_flush_delayed()
	_flush_hiding()
	if _prune() or _dirty or _device != InputTool.device_mode \
			or _last_device != InputTool.last_device \
			or _locale != TranslationServer.get_locale() or _binding != InputTool.binding_version:
		_render()

## 剔除已释放/已隐藏的来源（视图被回收时收不到 mouse_exit），返回是否移除过
static func _prune() -> bool:
	var removed := false
	for i in range(_stack.size() - 1, -1, -1):
		if _is_source_stale(_stack[i].source):
			_stack.remove_at(i)
			removed = true
	return removed

static func _flush_delayed() -> void:
	if _delayed.is_empty():
		return
	var now := Time.get_ticks_msec()
	for source in _delayed.keys():
		var pending: Dictionary = _delayed[source]
		if _is_source_stale(source):
			_delayed.erase(source)
		elif now >= pending.at:
			_push(source, pending.entries, pending.priority)

static func _flush_hiding() -> void:
	if _hiding.is_empty():
		return
	var now := Time.get_ticks_msec()
	for source in _hiding.keys():
		if now >= _hiding[source] or _is_source_stale(source):
			_hiding.erase(source)
			## 来源已释放时不能再当 Object 传参（freed 实例不满足参数类型），栈里失效条目由 _prune 收拾
			if is_instance_valid(source):
				_remove(source)

static func _render() -> void:
	_dirty = false
	if not _can_show():
		return
	_device = InputTool.device_mode
	_last_device = InputTool.last_device
	_locale = TranslationServer.get_locale()
	_binding = InputTool.binding_version
	var text := _format(_top().get("entries", []))
	if text.is_empty():
		_shown = false
		label.text = ""
		if is_instance_valid(tween):
			var t := tween.playback()
			if t:
				t.finished.connect(_hide_label, CONNECT_ONE_SHOT)
		else:
			label.visible = false
		return
	if label.text != text:
		label.text = text
	label.visible = true
	if not _shown:
		_shown = true
		if is_instance_valid(tween):
			tween.play()

## 收起动画只改变换，结束时再隐藏节点
static func _hide_label() -> void:
	if is_instance_valid(label):
		label.visible = false

## 当前应显示的提示（顺手剔除已释放/已隐藏 source 的条目）
static func _top() -> Dictionary:
	var top := {}
	var i := 0
	while i < _stack.size():
		var item: Dictionary = _stack[i]
		if _is_source_stale(item.source):
			_stack.remove_at(i)
			continue
		if top.is_empty() or item.priority >= top.priority:
			top = item
		i += 1
	return top

static func _find(source: Object) -> int:
	for i in _stack.size():
		if _stack[i].source == source:
			return i
	return -1

static func _remove(source: Object) -> void:
	var i := _find(source)
	if i < 0:
		return
	_stack.remove_at(i)
	_dirty = true

static func _unbind() -> void:
	if is_instance_valid(_tree) and _tree.process_frame.is_connected(_tick):
		_tree.process_frame.disconnect(_tick)
	_tree = null

static func _can_show() -> bool:
	return is_instance_valid(label) and label.is_inside_tree()

## source 失效：已释放，或所在视图已隐藏/移出树（视图被回收时收不到 mouse_exit）
static func _is_source_stale(source: Variant) -> bool:
	if source == null:
		## 已释放对象与 null 相等，靠 typeof 区分真 null（无来源，不剔除）
		return typeof(source) == TYPE_OBJECT
	return not NodeTreeTool.is_alive(source)

## 渲染提示行：同说明的键合并成 "键1/键2 说明"，各项用 · 分隔
static func _format(entries: Array) -> String:
	var groups := {}
	for entry in entries:
		var item := entry as Array
		if item.is_empty():
			continue
		## 第二个元素必须是文案 key；传错结构（如多套一层数组）时按无文案处理，不抛出
		var desc_key: Variant = item[1] if item.size() > 1 else ""
		var desc := str(TranslationServer.translate(desc_key)) if (desc_key is String or desc_key is StringName) else ""
		var src: Variant = item[0]
		if src is Array and src.is_empty():
			src = confirm_keys()
		var texts := _key_texts(src, InputTool.last_device)
		if texts.is_empty():
			## 当前设备没有这组键（鼠标没有"返回"）→ 键鼠共用键盘，仍不混入手柄
			texts = _key_texts(src, InputTool.InputDevice.KEYBOARD)
		var keys: Array = groups.get_or_add(desc, [])
		for text in texts:
			if not keys.has(text):
				keys.append(text)
	var parts := PackedStringArray()
	for desc in groups:
		var keys: Array = groups[desc]
		if keys.is_empty():
			## 当前设备没有绑定：保留文案，避免整条提示凭空消失
			if not desc.is_empty():
				parts.append(desc)
			continue
		parts.append(("%s %s" % ["/".join(PackedStringArray(keys)), desc]).strip_edges())
	return " · ".join(parts)

## 一组按键 → 文本（按设备过滤并去重）
static func _key_texts(src: Variant, device: int) -> Array:
	var texts := []
	for key in (src if src is Array else [src]):
		var text := InputTool.input_text(key, device)
		if not text.is_empty() and not texts.has(text):
			texts.append(text)
	return texts
