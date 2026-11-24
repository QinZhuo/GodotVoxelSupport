class_name Background extends Node2D

var bgs: Array[Parallax2D] = []

var screen_offset: Vector2:
	set(value):
		if screen_offset == value:
			return
		screen_offset = value
		_apply_offset()

func _ready() -> void:
	# 子节点不保证全是 Parallax2D; 带类型标注的 for 会直接抛错
	for child in get_children():
		if child is Parallax2D:
			child.ignore_camera_scroll = true
			bgs.append(child)
	# setter 可能早于 _ready 被赋值(场景加载即设), 那时 bgs 还是空的
	_apply_offset()

func _apply_offset() -> void:
	for bg in bgs:
		bg.screen_offset = screen_offset
