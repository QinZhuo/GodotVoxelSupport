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

## 被取出时：重置状态并播放（取出不等于重新入树，_ready 不会重跑，故由此补上）
func on_pool_get() -> void:
	_update_visible(true)

## 被归还进池时：停放待命，不播动画
## 否则动画播完会触发 tween 上的释放回调，把还在池里的自己销毁掉，池子就被悄悄掏空
func on_pool_push() -> void:
	if tween and tween.cur_tween:
		tween.cur_tween.kill()

func tween_free() -> void:
	TweenViewTool.finish_and_free(self, tween)
