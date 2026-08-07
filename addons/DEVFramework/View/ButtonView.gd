class_name ButtonView extends Button

@export var tween: TweenAnimation

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

## 子类重写此方法处理进入事件（鼠标悬停/聚焦）
func _mouse_enter() -> void:
	pass

## 子类重写此方法处理离开事件（鼠标离开/失焦）
func _mouse_exit() -> void:
	pass
