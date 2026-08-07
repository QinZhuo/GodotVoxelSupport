class_name Background extends Node2D

var bgs: Array[Parallax2D]

var screen_offset: Vector2:
	set(value):
		if screen_offset == value:
			return
		screen_offset = value
		for bg in bgs:
			bg.screen_offset = screen_offset

func _ready() -> void:
	for bg: Parallax2D in get_children():
		bg.ignore_camera_scroll = true
		bgs.append(bg)
