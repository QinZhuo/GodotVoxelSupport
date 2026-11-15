class_name UIPanelTool
extends RefCounted

## [UIPanel] / [UIPanel3D] 的共享打开/关闭状态机(纯静态工具, 与 [UITool] 同族)。
## 两个面板基类必须分别继承 [Control] / [Node3D](GDScript 无多继承), 无法共享基类,

## 应用面板显隐。走面板的 [method UIPanel3D.apply_visibility] / [method UIPanel.apply_visibility]，
static func _apply_visibility(panel, shown: bool) -> void:
	if panel.has_method(&"apply_visibility"):
		panel.apply_visibility(shown)
	else:
		panel.visible = shown


## 打开面板: 注册到 [UITool] 栈(含层级互斥) → [code]on_open[/code] → 显示 → 进入动画 → [code]on_opened[/code]
static func open(panel) -> void:
	panel._open_version += 1
	UITool.register(panel)
	panel.is_open = true
	panel.on_open.emit()
	_apply_visibility(panel, true)
	if panel.show_tween:
		await panel.show_tween.play().finished
	if not is_instance_valid(panel):
		return
	panel.on_opened.emit()


## 关闭面板: [code]on_close[/code] → 离开动画 → 隐藏 → [code]on_closed[/code] → 从 [UITool] 注销
static func close(panel) -> void:
	panel.is_open = false
	UITool.unregister(panel)
	panel.on_close.emit()
	if panel.show_tween:
		await panel.show_tween.playback().finished
	if not is_instance_valid(panel):
		return
	_apply_visibility(panel, false)
	panel.on_closed.emit()


## 离开场景树时的兜底注销。
## 会让后续 [method UITool.get_top] / 排序拿到悬空对象(实测报 "previously freed instance")。
## 这是唯一能兜住"没调 close 就没了"的位置 —— 各面板不必自己记得。
static func on_exit_tree(panel) -> void:
	if not panel.is_open:
		return
	panel.is_open = false
	UITool.unregister(panel)
	_apply_visibility(panel, false)
	panel.on_closed.emit()


## 切换打开/关闭
static func toggle(panel) -> void:
	if panel.is_open:
		await close(panel)
	else:
		await open(panel)


## 弹窗模式: 打开面板并等待其关闭(可用于异步等待面板交互结果)。
static func popup(panel) -> void:
	await open(panel)
	var ver = panel._open_version
	while is_instance_valid(panel) and panel.is_open and panel._open_version == ver:
		await panel.on_closed


## 等待面板关闭, 返回关闭时版本是否仍为本轮(期间被重新 open() 则旧等待返回 false)。
static func await_closed(panel) -> bool:
	var ver = panel._open_version
	await panel.on_closed
	return ver == panel._open_version
