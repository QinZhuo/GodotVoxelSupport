@tool
## SwingFollow2D 类继承自 Node2D，用于创建一个跟随目标节点的摆动效果
class_name SwingFollow2D extends Node2D

## 目标节点，将跟随此节点的移动
@export var target: Node2D:
	set(value):
		target = value
		if target:
			last_target_position = target.global_position

@export_range(0.1, 5) var speed_scale: float = 2
## 阻尼系数，控制摆动效果的衰减速度 数值越大阻尼效果越明显
@export_range(0.1, 10) var damping: float = 5

# 记录上一帧目标节点的位置
var last_target_position: Vector2

# 当前相对于目标的偏移量
var current_offset: Vector2 = Vector2.ZERO

# 偏移量变化的速度
var velocity: Vector2 = Vector2.ZERO

func _ready() -> void:
	if target:
		global_position = target.global_position

func _process(delta):
	if not target:
		return

	# 更新速度：根据目标位置的变化和当前偏移量来计算
	velocity += (target.global_position - last_target_position - current_offset) * speed_scale

	current_offset += velocity * delta

	# 应用阻尼：降低速度以模拟阻力
	velocity *= (1 - damping * delta)

	global_position = target.global_position + current_offset

	last_target_position = target.global_position
