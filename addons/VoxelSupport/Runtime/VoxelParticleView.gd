@tool
class_name VoxelParticleView
extends Node3D

## 粒子视图组件：把宿主的体素数据渲染成 GPU 粒子（每个体素一个方块/小球）。

## 粒子点数上限。
@export_range(100, 500000, 100) var max_points: int = 200000

## 只渲染表面体素（跳过被完全包住的）。
@export var surface_only: bool = true

## 自发光强度倍率，与网格路径的 `MATERIAL_EMISSION_ENERGY` 同量级。
@export_range(0.0, 100.0, 0.5) var emission_energy: float = 20.0:
	set(v):
		emission_energy = v
		apply_material_params()

## 粒子（体素方块）的显示尺寸倍率：1.0 = 与体素等比，拼起来严丝合缝。
@export_range(0.05, 3.0, 0.01) var particle_scale: float = 1.0:
	set(v):
		particle_scale = v
		apply_material_params()

## 粒子整体透明度（出场 / 退场淡出用）。
@export_range(0.0, 1.0, 0.01) var alpha: float = 1.0:
	set(v):
		alpha = v
		apply_material_params()

## 体素形状：0 = 方块（拼起来严丝合缝），1 = 球（观感柔和，散开后像粒子）。
@export_range(0, 1, 1) var voxel_shape: int = 0:
	set(v):
		voxel_shape = v
		_apply_shape()

## 球半径相对体素边长的比例（仅 `voxel_shape == 1` 时生效）。
@export_range(0.1, 2.0, 0.01) var sphere_scale: float = 1.0:
	set(v):
		sphere_scale = v
		_apply_shape()

## 球的面数分档。
@export_range(0, 2, 1) var sphere_subdivisions: int = 0:
	set(v):
		sphere_subdivisions = v
		_apply_shape()

## 按空间（Morton / Z-order）顺序重排点云后再上传。
@export var spatial_sort: bool = false

## 实际的 GPU 粒子节点（**公开**：项目可自己换 `process_material` 做运动效果）。
var particle_node: GPUParticles3D = null

## 最近一次导出的点数据（布局见 `QVoxelSource.build_particle_points`）。
var particle_points: PackedFloat32Array = PackedFloat32Array()

## 宿主（只读上下文来源；由 `configure()` 绑定，之后不变）。
var host: VoxelRenderer = null

# --- GPU 资源（懒创建：只有真要显示粒子时才建）---
var _process_mat: ShaderMaterial = null
var _draw_mat: ShaderMaterial = null
var _draw_trans_mat: ShaderMaterial = null
var _mesh: Mesh = null
var _mesh_trans: Mesh = null

## 绑定宿主。
func configure(host_ref: VoxelRenderer) -> void:
	if host == host_ref:
		return
	clear()
	host = host_ref

## 从宿主体素数据重建点云与 GPU 资源。
func rebuild() -> void:
	if host == null or host.data == null:
		clear()
		return
	# 点云导出唯一入口；`build_particle_points` 由它内部调用（数据层保持不动）。
	var tex := host.data.build_particle_textures(host.voxel_scale, max_points, surface_only)
	var count := int(tex.get("count", 0))
	if count <= 0:
		clear()
		return
	# 空间排序（可选）：必须在 _upload 之前完成 —— 纹理内容与 particle_points 要一起换序，
	if spatial_sort and count > 1:
		tex = _spatial_sorted(tex)
	particle_points = tex.get("points", PackedFloat32Array())
	_ensure_particle_node(count)
	_upload(tex)

## 释放粒子节点与点数据（宿主关闭粒子显示 / 退出 / 数据清空时调用）。
func clear() -> void:
	particle_points = PackedFloat32Array()
	_kill_node()

## 只把"材质类" uniform（voxel_size / emission_energy / alpha）重写给**绘制材质**，
func apply_material_params() -> void:
	var vs := voxel_size()
	for mat in [_draw_mat, _draw_trans_mat]:
		if mat == null:
			continue
		mat.set_shader_parameter(VoxelParticleShader.U_VOXEL_SIZE, vs)
		mat.set_shader_parameter(VoxelParticleShader.U_EMISSION_ENERGY, emission_energy)
		mat.set_shader_parameter(VoxelParticleShader.U_ALPHA, alpha)

## 粒子方块的边长（世界单位），写入绘制着色器的 `voxel_size`。
func voxel_size() -> float:
	var scale := host.voxel_scale if host != null else 0.1
	return scale * particle_scale

# ── 内部：GPU 资源 ─────────────────────────────────────────────────────────…

## 只销毁 GPU 节点、**不动 `particle_points`**。
func _kill_node() -> void:
	if particle_node != null:
		# 【必须先判 is_instance_valid】节点可能已被外部 queue_free 或随宿主一起销毁。
		if is_instance_valid(particle_node):
			particle_node.queue_free()
		particle_node = null

## 保证存在一个 amount == count 的粒子节点；数量变了就重建节点（保留 `particle_points`）。
func _ensure_particle_node(count: int) -> void:
	if particle_node != null and is_instance_valid(particle_node) and particle_node.amount == count:
		return
	_kill_node()
	if _process_mat == null:
		_process_mat = VoxelParticleShader.make_process_material()
	if _draw_mat == null:
		_draw_mat = VoxelParticleShader.make_draw_material()
	if _draw_trans_mat == null:
		_draw_trans_mat = VoxelParticleShader.make_draw_material_trans()
	_mesh = _make_mesh(_draw_mat)
	_mesh_trans = _make_mesh(_draw_trans_mat)

	var gp := GPUParticles3D.new()
	gp.name = "VoxelParticles"
	gp.amount = maxi(count, 1)
	gp.lifetime = 100.0
	# 【必须预热满一个 lifetime】否则粒子是"逐渐发射"的，第一帧只有几颗，
	gp.preprocess = 100.0
	gp.explosiveness = 0.0
	gp.local_coords = false
	gp.process_material = _process_mat
	# 两个 draw pass：不透明通道写深度（遮挡正确），透明通道不写深度（玻璃能透、不裁后面）
	gp.set_draw_passes(2)
	gp.set_draw_pass_mesh(0, _mesh)
	gp.set_draw_pass_mesh(1, _mesh_trans)
	# 【必须给 visibility_aabb】否则粒子飞出原始包围盒后会被视锥剔除整片消失
	gp.visibility_aabb = AABB(Vector3(-1000, -1000, -1000), Vector3(2000, 2000, 2000))
	gp.emitting = true
	add_child(gp)
	particle_node = gp
	gp.restart()

## 按 `voxel_shape` 生成粒子网格。
func _make_mesh(mat: Material) -> Mesh:
	# 【为什么声明成 PrimitiveMesh】`material` 属性属于 PrimitiveMesh；声明成 Mesh 虽能跑，
	var prim: PrimitiveMesh
	if voxel_shape == 1:
		var sphere := SphereMesh.new()
		# 【面数分档对齐网格路径的 icosphere 档位】20 / 80 / 320 面。
		var idx := clampi(sphere_subdivisions, 0, 2)
		sphere.rings = [6, 10, 18][idx]
		sphere.radial_segments = [8, 16, 32][idx]
		sphere.radius = 0.5 * sphere_scale
		sphere.height = 1.0 * sphere_scale
		prim = sphere
	else:
		var box := BoxMesh.new()
		box.size = Vector3.ONE
		prim = box
	prim.material = mat
	return prim

## 形状参数变了：只换两个 draw pass 的网格（**不重建粒子节点**，点云不受影响）。
func apply_shape() -> void:
	_apply_shape()

func _apply_shape() -> void:
	if particle_node == null or not is_instance_valid(particle_node):
		return
	if _draw_mat == null or _draw_trans_mat == null:
		return
	_mesh = _make_mesh(_draw_mat)
	_mesh_trans = _make_mesh(_draw_trans_mat)
	particle_node.set_draw_pass_mesh(0, _mesh)
	particle_node.set_draw_pass_mesh(1, _mesh_trans)

## 把点数组按空间（Morton）序重排，再用**导出器同一份烘焙**重出纹理字典。
func _spatial_sorted(tex: Dictionary) -> Dictionary:
	var pts: PackedFloat32Array = tex.get("points", PackedFloat32Array())
	var stride := int(tex.get("stride", VoxelPointCloudExporter.PARTICLE_STRIDE))
	var order := VoxelMorphMap.sorted_indices(pts, stride)
	if order.is_empty():
		return tex
	var reordered: PackedFloat32Array = VoxelMorphMap.reorder(pts, order, stride)
	var out: Dictionary = VoxelPointCloudExporter.textures_from_points(reordered)
	return out if int(out.get("count", 0)) > 0 else tex

## 上传点云纹理与材质 uniform。
func _upload(tex: Dictionary) -> void:
	if _process_mat == null:
		return
	_process_mat.set_shader_parameter(VoxelParticleShader.U_SRC_POS, tex["positions"])
	_process_mat.set_shader_parameter(VoxelParticleShader.U_DST_POS, tex["positions"])
	_process_mat.set_shader_parameter(VoxelParticleShader.U_COLORS, tex["colors"])
	_process_mat.set_shader_parameter(VoxelParticleShader.U_PROPS, tex["props"])
	_process_mat.set_shader_parameter(VoxelParticleShader.U_GRID_WIDTH, tex["grid_width"])
	# 进度停在 0：本组件不驱动运动，只负责把"当前形状"摆出来。
	_process_mat.set_shader_parameter(VoxelParticleShader.U_PROGRESS, 0.0)
	apply_material_params()

## 惰性绑定：宿主在 `_ready` 里 `add_child` 本组件即可，无需显式 configure。
func _ready() -> void:
	if host != null:
		return
	var parent := get_parent()
	if parent is VoxelRenderer:
		configure(parent as VoxelRenderer)
