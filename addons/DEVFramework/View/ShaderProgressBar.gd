@tool
class_name ShaderProgressBar extends Range

@export var item: CanvasItem:
	set(new_item):
		if item == new_item:
			return
		item = new_item
		if item:
			value_changed.connect(func(new_value):
				if offset_key:
					offset_ratio += last_ratio - ratio
					last_ratio = ratio
				item.material.set_shader_parameter(progress_key, lerp(from_value, to_value, ratio))
			)
@export var progress_key: String = "progress"
@export var offset_key: String = "offset"
@export var from_value: float = 0
@export var to_value: float = 1

var last_ratio := 0.0
var offset_ratio := 0.0:
	set(value):
		if offset_ratio == value:
			return
		offset_ratio = value
		item.material.set_shader_parameter(offset_key, offset_ratio * abs(from_value - to_value))

func _ready() -> void:
	last_ratio = ratio

func _process(delta: float) -> void:
	if offset_key and offset_ratio:
		offset_ratio = lerpf(offset_ratio, 0, delta * 5)
