class_name UIPanelTool
extends RefCounted

## [UIPanel] / [UIPanel3D] 的共享打开/关闭状态机(纯静态工具, 与 [UITool] 同族)。

## 应用面板显隐。
static func _apply_visibility(panel, shown: bool) -> void:
	if panel.has_method(&"apply_visibility"):
		panel.apply_visibility(shown)
	else:
		panel.visible = shown

## 打开面板: 注册到 [UITool] 栈(含层级互斥) → [code]on_open[/code] → 显示 → 进入动画 →…
static func open(panel) -> void:
	panel._open_version += 1
	UITool.register(panel)
	panel.is_open = true
	panel.on_open.emit()
	_apply_visibility(panel, true)
	if panel.show_tween:
		await TweenViewTool.await_done(panel, panel.show_tween.play())
	if not is_instance_valid(panel):
		return
	panel.on_opened.emit()

## 关闭面板: [code]on_close[/code] → 离开动画 → 隐藏 → [code]on_closed[/code] → 从…
static func close(panel) -> void:
	panel.is_open = false
	UITool.unregister(panel)
	panel.on_close.emit()
	if panel.show_tween:
		await TweenViewTool.await_done(panel, panel.show_tween.playback())
	if not is_instance_valid(panel):
		return
	_apply_visibility(panel, false)
	panel.on_closed.emit()

## 离开场景树时的兜底注销。
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
	if not is_instance_valid(panel):
		return
	var ver = panel._open_version
	while is_instance_valid(panel) and panel.is_open and panel._open_version == ver:
		await panel.on_closed

## 等待面板关闭, 返回关闭时版本是否仍为本轮(期间被重新 open() 则旧等待返回 false)。
static func await_closed(panel) -> bool:
	return await await_closed_since(panel, panel._open_version)

## 同上，但版本由调用方在 open() 之后自行捕获：淡入期间就被关掉时也能立刻返回，
static func await_closed_since(panel, version: int) -> bool:
	while is_instance_valid(panel) and panel.is_open and panel._open_version == version:
		await panel.on_closed
	if not is_instance_valid(panel):
		return false   # 面板已释放: 本轮不会再有关闭事件, 让调用方跳过后续动作
	return version == panel._open_version
