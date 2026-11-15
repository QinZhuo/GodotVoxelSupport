## 2D UI 面板基类
class_name UIPanel extends Control

# ============================================================

## 进入/离开动画，为空则直接切换显隐
@export var show_tween: TweenAnimation

## UI 层级（[UITool.Layer] 枚举值，数字越大越靠前）
@export var layer: UITool.Layer = UITool.Layer.PANEL

# ============================================================

var is_open: bool = false
## 每次 open() 自增，用于 await_closed() 检测版本是否过期
var _open_version := 0

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

## 返回键处理，由 [method UITool.back] 调用。默认关闭面板并返回 true（已消费）。
func _back() -> bool:
	close()
	return true

## 应用面板显隐（[UIPanelTool.open] / [UIPanelTool.close] 调用）。默认切换自身 [member visible]。
func apply_visibility(shown: bool) -> void:
	visible = shown

## 当前面板是否拥有焦点（快捷键应仅在聚焦时响应）。
func is_focus() -> bool:
	return UITool.is_focus(self)
