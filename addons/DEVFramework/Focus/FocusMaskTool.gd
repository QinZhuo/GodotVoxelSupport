class_name FocusMaskTool

## 焦点遮罩入口 — 全局唯一的 FocusMask, 首次使用时自动挂到最高层 CanvasLayer。
## 教程/过场/强制选择统一走这里: 聚焦 = 只有指定目标可交互, 其余变暗; 用完 clear()。

## 遮罩画布层级(默认盖住全部 UI)
static var layer: int = UITool.Layer.TOP

static var _mask: FocusMask


## 聚焦一组目标节点。opts 见 FocusMask.focus
## host 仅用于挂载画布层(默认挂在当前场景根节点, 随场景销毁)
static func focus(items: Array, opts: Dictionary = {}, host: Node = null) -> FocusMask:
	var mask := _ensure(host)
	if mask == null:
		return null
	mask.focus(items, opts, host)
	return mask


## 取消聚焦并隐藏遮罩(不释放节点, 下次复用)
static func clear() -> void:
	if is_instance_valid(_mask):
		_mask.clear()


## 更新提示文案(直接交给对话子系统, 锚点用当前遮罩的目标包围盒)
static func set_tip(text: String) -> void:
	if not is_instance_valid(_mask):
		return
	if text.is_empty():
		DialogueTool.hide()
		return
	DialogueTool.show(text, _mask.get_focus_rect())


static func is_active() -> bool:
	return is_instance_valid(_mask) and _mask.is_active()


## 是否有目标外输入被锁住(供外部禁用快捷键/操作)
static func is_blocking() -> bool:
	return is_instance_valid(_mask) and _mask.is_blocking()


static func get_mask() -> FocusMask:
	return _mask if is_instance_valid(_mask) else null


## 释放遮罩节点(切场景/回标题); 遮罩已在场景中被销毁时也安全
static func reset() -> void:
	if is_instance_valid(_mask):
		var canvas := _mask.get_parent()
		if canvas:
			canvas.queue_free()
		else:
			_mask.queue_free()
	_mask = null


static func _ensure(host: Node) -> FocusMask:
	if is_instance_valid(_mask) and _mask.is_inside_tree():
		return _mask
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var parent: Node = host if (host != null and host.is_inside_tree()) else tree.root
	var canvas := CanvasLayer.new()
	canvas.name = "FocusMaskLayer"
	canvas.layer = layer
	canvas.process_mode = Node.PROCESS_MODE_ALWAYS  # 暂停(暂停过场/暂停菜单)时仍可遮罩与拦截
	parent.add_child(canvas)
	_mask = FocusMask.new()
	_mask.name = "FocusMask"
	canvas.add_child(_mask)
	_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return _mask
