## 2D UI 面板基类
##
## 编写 2D UI 时继承此类，提供统一的打开/关闭生命周期。
## [method open] — 先注册到 [UITool] 进行栈管理与层级互斥，然后执行进入动画。
## [method close] — 执行离开动画并从 [UITool] 自动注销，动画结束后隐藏。
## 通过连接 [signal on_open] / [signal on_close] 等信号实现自定义动画。
##
## 状态机实现见 [UIPanelTool]（与 [UIPanel3D] 共用，避免两份实现漂移）。
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

## 打开面板。完整流程见 [UIPanelTool.open]。
func open() -> void:
	await UIPanelTool.open(self)

## 关闭面板。完整流程见 [UIPanelTool.close]。
func close() -> void:
	await UIPanelTool.close(self)

## 节点离开场景树时自动注销（兜底，见 [UIPanelTool.on_exit_tree]）。
func _exit_tree() -> void:
	UIPanelTool.on_exit_tree(self)

## 切换打开/关闭。
func toggle() -> void:
	await UIPanelTool.toggle(self)

## 弹窗模式：打开面板并等待关闭（可用于异步等待面板交互结果）。
func popup() -> void:
	await UIPanelTool.popup(self)

## 等待面板关闭，返回关闭时版本是否仍为本轮（面板被重新 open() 后旧等待返回 false）。
func await_closed() -> bool:
	return await UIPanelTool.await_closed(self)

## 返回键处理，由 UITool.back() 调用。子类可重写自定义返回行为，默认关闭面板。
func _back() -> void:
	close()

## 当前面板是否拥有焦点（快捷键应仅在聚焦时响应）。
func is_focus() -> bool:
	return UITool.is_focus(self)
