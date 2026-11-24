@tool
class_name ShaderProgressBar extends Range

@export var item: CanvasItem:
	set(new_item):
		if item == new_item:
			return
		# 换目标必须断开旧连接: lambda 每赋一次就多挂一个, 之后每次改值会重复写 shader
		if value_changed.is_connected(_apply_value):
			value_changed.disconnect(_apply_value)
		item = new_item
		if item:
			value_changed.connect(_apply_value)
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
		if item == null or item.material == null:
			return
		item.material.set_shader_parameter(offset_key, offset_ratio * abs(from_value - to_value))

func _apply_value(_new_value: float) -> void:
	if item == null or item.material == null:
		return
	if offset_key:
		offset_ratio += last_ratio - ratio
		last_ratio = ratio
	item.material.set_shader_parameter(progress_key, lerp(from_value, to_value, ratio))

func _ready() -> void:
	last_ratio = ratio

func _process(delta: float) -> void:
	if offset_key and offset_ratio:
		offset_ratio = lerpf(offset_ratio, 0, delta * 5)
