@tool
## 朝向行为: 让机位始终瞄准 [member VirtualCamera3D.target]。
##
## 结果同时用作球面/柱面混合的枢纽点(见 [method get_aim_point])。
## 注意: 使用本机位时机位不应挂在带缩放的父节点下。
class_name LookAtBehaviorDef extends CameraBehaviorDef

## 瞄准点相对目标的偏移(世界轴向)
@export var offset: Vector3 = Vector3.ZERO
## 朝向平滑时间(秒), 0 = 硬对准
@export_range(0, 2, 0.01, "or_greater") var damping: float = 0.0
## 参考上方向; 视线与该轴接近平行时自动改用相机右轴, 避免朝向翻转
@export var up: Vector3 = Vector3.UP


func apply(vcam: VirtualCamera3D, delta: float, instant: bool = false) -> void:
	var target: Node3D = vcam.target
	if target == null or not is_instance_valid(target):
		return
	var dir := target.global_position + offset - vcam.global_position
	if dir.length_squared() <= 0.000001:
		return
	var want := Basis.looking_at(dir, _resolve_up(vcam, dir)).get_rotation_quaternion()
	var weight := CameraTool.damp_weight(0.0 if instant else damping, delta)
	vcam.global_basis = Basis(vcam.global_basis.get_rotation_quaternion().slerp(want, weight))


func get_aim_point(vcam: VirtualCamera3D) -> Variant:
	var target: Node3D = vcam.target
	if target == null or not is_instance_valid(target):
		return null
	return target.global_position + offset


## 视线与参考 up 接近平行时, 改用相机右轴避免 Basis.looking_at 翻转
func _resolve_up(vcam: VirtualCamera3D, dir: Vector3) -> Vector3:
	var up_dir := up.normalized()
	if up_dir.length_squared() < 0.000001:
		return Vector3.UP
	if absf(dir.normalized().dot(up_dir)) > 0.999:
		var right := vcam.global_basis.x.normalized()
		return right if right.length_squared() > 0.000001 else Vector3.RIGHT
	return up_dir
