@tool
## 跟随行为: 让机位跟随 [member VirtualCamera3D.target] 的位置。
##
## 支持偏移、按目标朝向计算偏移、按轴独立阻尼, 以及死区 + 软区(消除目标小幅抖动导致的画面晃动)。
class_name FollowBehaviorDef extends CameraBehaviorDef

## 相对目标的位置偏移
@export var offset: Vector3 = Vector3.ZERO
## 偏移是否按目标自身朝向计算(false = 世界轴向)
@export var use_target_basis: bool = false
## 各轴的时间常数(秒), 0 = 该轴硬跟随; 越大越"懒"。分轴设置可做到"水平跟得紧、垂直更缓"
@export var damping: Vector3 = Vector3.ZERO
## 死区半尺寸(机位局部空间): 目标留在框内时相机完全不动
@export var dead_zone: Vector3 = Vector3.ZERO
## 软区厚度(机位局部空间): 目标越出死区后, 在此厚度内追赶速度与超出量成正比; 0 = 出死区即全速追
@export var soft_zone: Vector3 = Vector3.ZERO


func apply(vcam: VirtualCamera3D, delta: float, instant: bool = false) -> void:
	var target: Node3D = vcam.target
	if target == null or not is_instance_valid(target):
		return
	var desired := target.global_position
	desired += target.global_basis * offset if use_target_basis else offset
	desired = _apply_zone(vcam, desired)
	var weight := Vector3.ONE if instant else CameraTool.damp_weight3(damping, delta)
	var from := vcam.global_position
	vcam.global_position = Vector3(
		lerpf(from.x, desired.x, weight.x),
		lerpf(from.y, desired.y, weight.y),
		lerpf(from.z, desired.z, weight.z),
	)


## 死区 + 软区: 目标留在死区内相机不动; 越出后按超出量/软区厚度成比例追赶, 出软区则全速。
## 在机位局部空间计算, 因此死区随镜头朝向走(等价于屏幕空间的框)。
func _apply_zone(vcam: VirtualCamera3D, desired: Vector3) -> Vector3:
	if dead_zone == Vector3.ZERO:
		return desired
	var basis := vcam.global_basis
	var local := basis.inverse() * (desired - vcam.global_position)
	var push := Vector3.ZERO
	for i in 3:
		var d: float = local[i]
		var dead: float = dead_zone[i]
		if dead <= 0.0:
			push[i] = d
			continue
		var excess: float = absf(d) - dead
		if excess <= 0.0:
			continue
		var soft: float = soft_zone[i]
		var ratio := 1.0 if soft <= 0.0 else clampf(excess / soft, 0.0, 1.0)
		push[i] = signf(d) * excess * ratio
	return vcam.global_position + basis * push
