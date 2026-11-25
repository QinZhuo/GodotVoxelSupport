@tool
class_name VoxelParticleView
extends Node3D

## 粒子视图组件：把宿主的体素数据渲染成 GPU 粒子（每个体素一个方块/小球）。
##
## 【负责】`host.data` → 点云纹理 → 建/复用 `GPUParticles3D` → 上传位置/颜色/材质属性三张
##   纹理与双通道绘制材质（不透明 + 透明），以及"形状旋钮变了就换 draw mesh"。
## 【不负责】
##   · **粒子怎么动**（漂浮 / 消散 / 变形 / 聚合）—— 那是项目自己的表现。本组件只保证
##     "当前形状被静态摆出来"；要动就换 `particle_node.process_material`（见 VoxelParticleShader）。
##   · 显示模式切换（网格 / 粒子谁可见）—— 归宿主，本组件只建粒子节点；
##   · 有没有数据变化 —— 宿主在 `data.changed` / `voxel_scale` 变化后调 `rebuild()`。
## 【依赖方向】
##   · 宿主 → 本组件：`configure(host)` / `rebuild()` / `clear()` / `apply_material_params()`，
##     以及读 `particle_node` / `particle_points` 做自己的表现。
##   · 本组件 → 宿主：**只读**公开面 `host.data`（派生查询 `build_particle_textures`）与
##     `host.voxel_scale`。**不碰宿主私有成员**。
##   · 本组件 → `VoxelParticleShader`：复用其 process/draw 着色器，不另写着色器。
## 【为什么是宿主的子节点】identity 变换 → `global_position` 即宿主世界位置；点云坐标本就是
##   "世界单位（含 center_offset × voxel_scale）"，故与网格渲染天然重合。
## 【为什么重建要显式调用】一次 `build_particle_textures` 是几十毫秒级（20 万点量级），
##   只应在数据 / 缩放 / 旋钮变化时做；纯运动变化不该触发它。

## 粒子点数上限。超出按确定性抽样缩减（同输入同输出，回放可复现）。
@export_range(100, 500000, 100) var max_points: int = 200000

## 只渲染表面体素（跳过被完全包住的）。**透明体素永远保留**（玻璃被包住也看得见后面）。
## 散开 / 漂浮 / 变形类效果应关掉 —— 那时内部体素散开后是看得见的。
@export var surface_only: bool = true

## 自发光强度倍率，与网格路径的 `MATERIAL_EMISSION_ENERGY` 同量级。
## 与下面三个旋钮一样，只改着色器 uniform，**不重导点云**（它们不影响点云内容）。
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
## 【为什么是 int 而不是引用宿主的 VoxelShape 枚举】宿主已持有本组件的类型引用，
## 反向引用枚举会构成脚本循环依赖；数值约定与 `VoxelRenderer.VoxelShape` 一一对应。
@export_range(0, 1, 1) var voxel_shape: int = 0:
	set(v):
		voxel_shape = v
		_apply_shape()

## 球半径相对体素边长的比例（仅 `voxel_shape == 1` 时生效）。
@export_range(0.1, 2.0, 0.01) var sphere_scale: float = 1.0:
	set(v):
		sphere_scale = v
		_apply_shape()

## 球的面数分档。0 = 20 面（最省），1 = 80 面，2 = 320 面（与网格路径档位对齐）。
@export_range(0, 2, 1) var sphere_subdivisions: int = 0:
	set(v):
		sphere_subdivisions = v
		_apply_shape()

## 按空间（Morton / Z-order）顺序重排点云后再上传。
##
## 【为什么值得开】GPU 逐线程按 INDEX 顺序取点时，相邻线程拿到的点在纹理里也相邻 →
## 采样缓存命中率更高，且"取包围盒内的点"从全表扫退化成扫一段连续区间。
## 代价是 rebuild() 时多一次排序 + 三张纹理的整块像素搬运（20 万点量级约几十毫秒，只做一次）。
##
## 【语义不变】只是**同一个点排到另一个槽位**：点集、颜色、材质、数量都不变，
## 静态渲染画面完全相同；影响的只有"点的访问顺序"。
## 【什么时候别开】项目自己按 INDEX 做形态变换（A[i] ↔ B[i] 硬配对）时，重排会破坏它的对应关系
##   —— 那种场景应关掉，或自己拿 `VoxelMorphMap.build` 做配对表。
## 【为什么这里没有 setter】与 `max_points` / `surface_only` 同一类旋钮：它们改的是**点云内容**，
##   一旦带 setter 就变成"改一下重导 20 万点"，Inspector 里拖一下都卡。改完由宿主调 `rebuild()`
##   （宿主入口是 `VoxelRenderer.rebuild_particles()`）。
@export var spatial_sort: bool = false

## 实际的 GPU 粒子节点（**公开**：项目可自己换 `process_material` 做运动效果）。
var particle_node: GPUParticles3D = null

## 最近一次导出的点数据（布局见 `QVoxelSource.build_particle_points`）。**公开**：
## 项目若要自己做形态变换（配对 / 偏移 / 映射），可直接拿它算，不必再问数据层。
var particle_points: PackedFloat32Array = PackedFloat32Array()

## 宿主（只读上下文来源；由 `configure()` 绑定，之后不变）。
var host: VoxelRenderer = null

# --- GPU 资源（懒创建：只有真要显示粒子时才建）---
var _process_mat: ShaderMaterial = null
var _draw_mat: ShaderMaterial = null
var _draw_trans_mat: ShaderMaterial = null
var _mesh: Mesh = null
var _mesh_trans: Mesh = null


## 绑定宿主。可重复调用（幂等）；换宿主时先清掉旧粒子节点（点云属于旧数据）。
func configure(host_ref: VoxelRenderer) -> void:
	if host == host_ref:
		return
	clear()
	host = host_ref


## 从宿主体素数据重建点云与 GPU 资源。
## 【何时调用】数据改了、`voxel_scale` 改了、本组件旋钮改了 —— 任何影响点云内容的变化。
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
	# 否则"位置纹理是排好的、公开点数组是原始序"，项目拿 particle_points 做二次计算就会错位。
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
## **不重导点云、不重建节点**。
## 【为什么单独开一个公开方法】项目做整体淡出时每帧改 `alpha`，若只能靠 `rebuild()`
##   生效就等于每帧重导 20 万点 —— 那是致命的。
## 【为什么这里不碰 _process_mat】透明度是**绘制期**的事：不透明通道把它当硬阈值 discard、
##   透明通道把它乘进 ALPHA。粒子更新着色器（shader_type particles）只写 TRANSFORM/COLOR/CUSTOM，
##   既不读 alpha、也不可能改绘制期的透明度 —— 早先那句
##   `_process_mat.set_shader_parameter(U_ALPHA, alpha)` 写了但从来没有任何效果，已删。
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


# ── 内部：GPU 资源 ────────────────────────────────────────────────────────────

## 只销毁 GPU 节点、**不动 `particle_points`**。
## 【为什么要拆开】`rebuild()` 先算好点数组再调 `_ensure_particle_node`，后者在"数量变了"
## 时需要销毁旧节点 —— 若它调 `clear()` 就会把刚导出的点数组清空。
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
	# 起点形状根本不成形（实测踩过：连续三次渲染都只有几个散点）。
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


## 按 `voxel_shape` 生成粒子网格。尺寸由绘制着色器统一缩放，故这里一律**单位尺度**：
## 立方体边长 1、球直径 1（球按同一边长缩放后正好内切于体素格）。
func _make_mesh(mat: Material) -> Mesh:
	# 【为什么声明成 PrimitiveMesh】`material` 属性属于 PrimitiveMesh；声明成 Mesh 虽能跑，
	# 但静态类型上不存在该成员，改类型时会炸。
	var prim: PrimitiveMesh
	if voxel_shape == 1:
		var sphere := SphereMesh.new()
		# 【面数分档对齐网格路径的 icosphere 档位】20 / 80 / 320 面。
		# SphereMesh 是 UV 球，用 rings/radial_segments 近似：0 -> 6x8、1 -> 10x16、2 -> 18x32。
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
## 形状/球参数变了之后重建 draw mesh（不重建粒子节点、不重导点云）。
## 【为什么公开】宿主的 `voxel_shape` / `sphere_scale` / `sphere_subdivisions` 是 Inspector
## 唯一真值，它改完旋钮后要能通知本组件按新形状换 mesh；这三个旋钮不影响点云内容，
## 所以走这条轻量路径而不是 `rebuild()`。
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
##
## 【为什么重烘焙而不是搬像素】像素是"逐点定长"的，理论上把第 k 个像素写成原第 order[k] 个
##   像素就够。但那是第二份字节布局实现（格式、每像素字节数、通道顺序各抄一遍），排序后还要
##   逐个像素拷 3 张纹理；而导出器的 `textures_from_points` 就是"点数组 → 纹理"的唯一真值，
##   把排好序的数组丢回去即可 —— 无字节拷贝、无第二份 stride、无第二份 gamma 约定。
##   代价是多算一次逐点 sRGB→线性，比整块像素搬运便宜，且只在本函数被调用时付一次。
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
## 【编辑器行为】@tool 下不自动 rebuild —— 点云导出是几十毫秒级的重活，
## 编辑器里由宿主按自己的 `update_in_editor` 决定是否触发，避免打开场景就卡。
func _ready() -> void:
	if host != null:
		return
	var parent := get_parent()
	if parent is VoxelRenderer:
		configure(parent as VoxelRenderer)
