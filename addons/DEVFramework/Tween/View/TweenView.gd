class_name TweenView extends Control

@export var tween: TweenAnimation

@export var tween_visible: bool = true:
	set(value):
		if tween_visible == value:
			return
		tween_visible = value
		_update_visible(false)

func _ready() -> void:
	_update_visible(true)

func _update_visible(reset: bool):
	TweenViewTool.update_visible(tween, tween_visible, reset)

func tween_free() -> void:
	TweenViewTool.finish_and_free(self, tween)
