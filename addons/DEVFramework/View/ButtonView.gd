class_name ButtonView extends Button

## 2D 可交互视图基类：悬停/焦点统一驱动缩放与快捷键提示，业务表现由子类 super 扩展。

@export var tween: TweenAnimation
@export var enter_tween: TweenAnimation
## 悬停提示文案 key（tip.csv），留空则不提示；动态文案或多键提示重写 get_click_tip()
@export var click_tip: StringName
## 悬停提示优先级：大于常驻流程提示时优先显示
@export var click_tip_priority: int = 0

@export var tween_visible: bool = true:
	set(value):
		if tween_visible == value:
			return
		tween_visible = value
		_update_visible(false)

func _ready() -> void:
	_update_visible(true)
	mouse_entered.connect(_mouse_enter)
	mouse_exited.connect(_mouse_exit)
	focus_entered.connect(_mouse_enter)
	focus_exited.connect(_mouse_exit)

func _update_visible(reset: bool) -> void:
	TweenViewTool.update_visible(tween, tween_visible, reset)

func tween_free() -> void:
	TweenViewTool.finish_and_free(self, tween)

## 进入事件（鼠标悬停/键盘聚焦）
func _mouse_enter() -> void:
	if enter_tween:
		enter_tween.play()
	TipTool.show_tip(get_click_tip(), self, click_tip_priority, TipTool.hover_delay)

## 离开事件
func _mouse_exit() -> void:
	TipTool.hide_tip(self, TipTool.hide_delay)
	if enter_tween:
		enter_tween.playback()

## 返回文案 key，或 [[按键, key], ...] 条目；返回空则不提示。随状态变化时重写这里
func get_click_tip() -> Variant:
	return click_tip
