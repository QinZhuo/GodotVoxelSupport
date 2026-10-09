class_name UIPanelTool
extends RefCounted

## [UIPanel] / [UIPanel3D] 的共享打开/关闭状态机(纯静态工具, 与 [UITool] 同族)。
##
## 两个面板基类必须分别继承 [Control] / [Node3D](GDScript 无多继承), 无法共享基类,
## 于是把两处共用的流程收敛到本类、面板只做薄转调 —— 避免两份近乎逐行相同的实现各自漂移
## (历史实现即出现过 3D 版 popup() 未 await、2D 版 close() 不隐藏 这类分叉)。
##
## [b]面板需提供的契约[/b](鸭子式, 由 [UIPanel] / [UIPanel3D] 提供):
## [br]· 属性 [code]is_open: bool[/code]、[code]_open_version: int[/code]、[code]show_tween[/code]、[code]visible[/code]
## [br]· 信号 [code]on_open[/code] / [code]on_opened[/code] / [code]on_close[/code] / [code]on_closed[/code]
##
## 参数刻意不标注类型: Control 与 Node3D 的公共成员(visible / 自定义信号)无法用单一基类表达,
## 只能动态派发到具体面板。

## 打开面板: 注册到 [UITool] 栈(含层级互斥) → [code]on_open[/code] → 显示 → 进入动画 → [code]on_opened[/code]
static func open(panel) -> void:
	panel._open_version += 1
	UITool.register(panel)
	panel.is_open = true
	panel.on_open.emit()
	panel.visible = true
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
	panel.visible = false
	panel.on_closed.emit()


## 离开场景树时的兜底注销。
##
## 面板被 free(换场景 / 节点被释放)时 [method close] 未必有机会被调用, 而栈里留一个已释放引用,
## 会让后续 [method UITool.get_top] / 排序拿到悬空对象(实测报 "previously freed instance")。
## 这是唯一能兜住"没调 close 就没了"的位置 —— 各面板不必自己记得。
static func on_exit_tree(panel) -> void:
	if not panel.is_open:
		return
	panel.is_open = false
	UITool.unregister(panel)
	panel.visible = false
	panel.on_closed.emit()


## 切换打开/关闭
static func toggle(panel) -> void:
	if panel.is_open:
		await close(panel)
	else:
		await open(panel)


## 弹窗模式: 打开面板并等待其关闭(可用于异步等待面板交互结果)。
##
## 打开过程中就已被关闭时, 循环条件里的 [code]is_open[/code] 判定会让它立即返回, 不会漏掉信号而永久挂起。
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
