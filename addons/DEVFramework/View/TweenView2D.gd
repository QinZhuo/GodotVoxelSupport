class_name TweenView2D extends Node2D

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
	if tween:
		if tween_visible:
			if reset:
				tween.play_reset()
			else:
				tween.play()
		else:
			tween.playback()

func tween_free() -> void:
	TweenViewTool.finish_and_free(self, tween)
