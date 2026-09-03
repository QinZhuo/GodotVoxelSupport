@tool
## 虚拟机位可视化: 在 3D 视图里画出机位视锥与上方向, 生效中的机位高亮为橙色。
## 由 DEVFramework 插件在 _enter_tree() 中注册(无 class_name, 仅编辑器加载)。
extends EditorNode3DGizmoPlugin

## 视锥线框长度(米)与假定画面宽高比
const FRUSTUM_LENGTH := 1.2
const ASPECT := 16.0 / 9.0
## 机位未覆盖 fov 时用于画线框的参考视场角
const DEFAULT_FOV := 60.0


func _init() -> void:
	create_material("idle", Color(0.35, 0.75, 1.0))
	create_material("active", Color(1.0, 0.72, 0.2))


func _get_gizmo_name() -> String:
	return "VirtualCamera3D"


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is VirtualCamera3D


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var vcam := gizmo.get_node_3d() as VirtualCamera3D
	if vcam == null:
		return
	var fov: float = vcam.lens_fov if vcam.lens_fov > 0.0 else DEFAULT_FOV
	var half_h := tan(deg_to_rad(fov * 0.5)) * FRUSTUM_LENGTH
	var half_w := half_h * ASPECT
	var z := -FRUSTUM_LENGTH
	var lt := Vector3(-half_w, half_h, z)
	var rt := Vector3(half_w, half_h, z)
	var rb := Vector3(half_w, -half_h, z)
	var lb := Vector3(-half_w, -half_h, z)
	var top := Vector3(0.0, half_h * 1.5, z)
	var lines := PackedVector3Array([
		# 四条视锥棱
		Vector3.ZERO, lt, Vector3.ZERO, rt, Vector3.ZERO, rb, Vector3.ZERO, lb,
		# 成像面矩形
		lt, rt, rt, rb, rb, lb, lb, lt,
		# 上方向标记(小三角)
		lt, top, top, rt,
	])
	gizmo.add_lines(lines, get_material("active" if vcam.active else "idle", gizmo), false)
	gizmo.add_collision_segments(lines)
