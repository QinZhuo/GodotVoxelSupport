@tool
## 对话/提示的**表现基类** — 只有四个可覆盖的方法 + 一个锚点。
##
## 想换样子就继承它，实现 `present()` / `dismiss()`（`refresh()` / `attach_slot()` 可选）：
##     立绘、打字机、多选框、字幕、3D 头顶文字都能做。
## 框架自带的 `BubbleView` 只是默认实现，不需要就用你的。
class_name DialogueView extends Control

## 玩家要求推进（点击/按键）—— 由 view 发出，DialogueTool 负责换行
signal advance_requested
## 每次排版完成（项目要做二次布局就接这个）
signal placed
signal shown
signal dismissed

## 排版后气泡顶部不得高于该 Y(-1 = 不限)。用于避开屏幕底部的按钮/物品栏
@export var limit_top := -1.0
## (定位策略见 place_default)

var _anchor := Rect2()
var _view := Vector2.ZERO


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------
# 项目实现这四个（都有空实现，不会因为没写而崩）
# ------------------------------------------------------------

## 显示一行；line 可能为 null（纯提示），此时用 text。
func present(_line: DialogueLineDef, text: String) -> void:
	visible = not text.is_empty()


## 收起
func dismiss() -> void:
	visible = false
	dismissed.emit()


## 内容/尺寸变化后重排
func refresh() -> void:
	pass


## 挂一个插槽（立绘/模型/图标）；框架只负责把锚点给它，排布由项目定
func attach_slot(_slot_name: StringName, _node: Control, _size: Vector2) -> void:
	pass


# ------------------------------------------------------------
# 框架提供
# ------------------------------------------------------------

## 调用方每帧喂"锚在哪"（空 Rect2 = 没有目标）
func set_anchor_rect(rect: Rect2, view_size: Vector2) -> void:
	if rect == _anchor and view_size == _view:
		return
	_anchor = rect
	_view = view_size
	refresh()


func anchor() -> Rect2:
	return _anchor


func view_size() -> Vector2:
	var view := _view
	if view.x <= 0.0 or view.y <= 0.0:
		view = get_viewport_rect().size
	return view


## 唯一保留的定位助手：有锚点贴其下方（放不下翻上方），没锚点贴屏幕底部居中。
## 想要别的摆法，直接在 `refresh()` 里自己算——不需要框架提供枚举。
func place_default(size: Vector2) -> Vector2:
	var view := view_size()
	var margin := 12.0
	var pos := Vector2(view.x * 0.5 - size.x * 0.5, view.y - margin - size.y)
	if _anchor.size != Vector2.ZERO:
		pos = Vector2(_anchor.get_center().x - size.x * 0.5, _anchor.end.y + 14.0)
		if pos.y + size.y > view.y - margin:
			pos.y = _anchor.position.y - 14.0 - size.y
	pos.x = clampf(pos.x, margin, maxf(margin, view.x - size.x - margin))
	pos.y = clampf(pos.y, margin, maxf(margin, view.y - size.y - margin))
	if limit_top >= 0.0:
		pos.y = maxf(pos.y, limit_top)
	return pos
