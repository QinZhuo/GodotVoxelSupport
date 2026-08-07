## 2D UI 面板基类
##
## 编写 2D UI 时继承此类，提供统一的打开/关闭生命周期。
## [method open] — 先注册到 [UITool] 进行栈管理与层级互斥，然后执行进入动画。
## [method close] — 先执行离开动画，然后从 [UITool] 自动注销。
## 通过连接 [signal on_open] / [signal on_close] 等信号实现自定义动画。
##
## 使用方式：
##   [codeblock]
##   my_panel.open()                   # 注册到 UITool 并显示（推荐）
##   my_panel.close()                  # 隐藏并从 UITool 注销（推荐）
##   my_panel.toggle()                 # 切换打开/关闭
##   UITool.register(my_panel)      # 仅注册到栈（不触发显示）
##   UITool.unregister(my_panel)    # 仅从栈注销（不触发隐藏）
##   [/codeblock]
class_name UIPanel extends Control

# ============================================================
# 导出属性
# ============================================================

## 进入/离开动画，为空则直接切换显隐
@export var show_tween: TweenAnimation

## UI 层级（[UITool.Layer] 枚举值，数字越大越靠前）
@export var layer: UITool.Layer = UITool.Layer.PANEL

# ============================================================
# 状态
# ============================================================

var is_open: bool = false
## 每次 open() 自增，用于 await_closed() 检测版本是否过期
var _open_version := 0

# ============================================================
# 信号
# ============================================================

## 打开动画开始前触发
signal on_open()
## 打开动画完成后触发
signal on_opened()
## 关闭动画开始前触发
signal on_close()
## 关闭动画完成后触发
signal on_closed()


# ============================================================
# 公开接口
# ============================================================

## 打开面板
##
## 完整流程：注册到 [UITool] 栈（处理层级互斥）→ 触发 [signal on_open] → 显示 → 播放进入动画 → 触发 [signal on_opened]。
func open() -> void:
	_open_version += 1
	# 注册到 UITool 栈（处理层级互斥）
	UITool.register(self)
	is_open = true
	on_open.emit()
	show()
	if show_tween:
		await show_tween.play().finished
	on_opened.emit()

## 关闭面板。
func close() -> void:
	is_open = false
	# 从 UITool 栈注销
	UITool.unregister(self)
	on_close.emit()
	if show_tween:
		await show_tween.playback().finished
	on_closed.emit()
	hide()

## 切换打开/关闭。完整流程见 [method open] / [method close]。
func toggle() -> void:
	if is_open:
		await close()
	else:
		await open()

## 弹窗模式：打开面板并等待关闭（可用于异步等待面板交互结果）。
func popup() -> void:
	await open()
	await on_closed

## 等待面板关闭，返回关闭时版本是否仍为本轮（面板被重新 open() 后旧等待返回 false）。
func await_closed() -> bool:
	var ver := _open_version
	await on_closed
	return ver == _open_version

## 返回键处理，由 UITool.back() 调用。子类可重写自定义返回行为，默认关闭面板。
func _back() -> void:
	close()

## 当前面板是否拥有焦点（快捷键应仅在聚焦时响应）。
func is_focus() -> bool:
	return UITool.is_focus(self)
