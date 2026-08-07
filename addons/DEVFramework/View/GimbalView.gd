@tool
class_name GimbalView extends Control

@export var parent_owner_deep: int = 1

var gimbal_target: CanvasItem:
	set(value):
		if gimbal_target == value:
			return
		if gimbal_target:
			gimbal_target.visibility_changed.disconnect(reset_view)
		gimbal_target = value
		if gimbal_target:
			gimbal_target.visibility_changed.connect(reset_view)
		reset_view()

func _ready():
	pivot_offset_ratio = Vector2.ONE * 0.5
	var target = self
	for i in parent_owner_deep:
		var parent := target.get_parent()
		if parent and parent.owner is CanvasItem:
			target = parent.owner
	gimbal_target = target

func reset_view():
	if gimbal_target:
		scale = scale * Vector2(1 if gimbal_target.scale.x > 0 else -1, 1 if gimbal_target.scale.y > 0 else -1)
		rotation_degrees = - gimbal_target.rotation_degrees
