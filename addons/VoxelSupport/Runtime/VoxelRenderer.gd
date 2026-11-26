@tool
class_name VoxelRenderer
extends MeshInstance3D

## 体素专属渲染器

# 【INF】视点相关成员标记约定

signal mesh_updated

# ── 粒子渲染（可选）──────────────────────────────────────────────────────────

## 显示方式：网格（合并面片）还是粒子（每个体素一个方块）。
enum DisplayMode {
	MESH,       ## 合并面片网格（默认，性能最好）
	PARTICLES,  ## 每个体素一个 GPU 粒子方块（可做形变类表现）
}

## 当前显示方式。
@export var display_mode: DisplayMode = DisplayMode.MESH:
	set(v):
		display_mode = v
		_apply_display_mode()

## 体素的显示形状：方块还是球。
enum VoxelShape {
	CUBE,    ## 体素方块（默认，拼起来严丝合缝）
	SPHERE,  ## 小球（观感柔和，散开后像粒子）
}

## 体素显示形状。
@export var voxel_shape: VoxelShape = VoxelShape.CUBE:
	set(v):
		voxel_shape = v
		# 两种形状都必须整体重建：方块面不能靠换材质变成球，球面也不能靠换材质变回方块。
		_clear_lod_meshes()
		if data:
			for ck in data.get_loaded_chunk_keys():
				data.mark_chunk_dirty(ck)
		request_update()
		if _particle_view != null and _particle_view.particle_node != null:
			_sync_particle_view_config()
			_particle_view.apply_shape()

## 球半径相对体素边长的比例（两种模式共用）。
@export_range(0.1, 2.0, 0.01) var sphere_scale: float = 1.0:
	set(v):
		sphere_scale = v
		_rebuild_for_shape_change()

## 球的面数分档。
@export_range(0, 2, 1) var sphere_subdivisions: int = 0:
	set(v):
		sphere_subdivisions = v
		_rebuild_for_shape_change()

## 形状参数变了：网格要按新形状重建（球面与方块面不是同一份几何），粒子换 draw mesh。
func _rebuild_for_shape_change() -> void:
	if _particle_view != null and _particle_view.particle_node != null:
		_sync_particle_view_config()
		_particle_view.apply_shape()
	_clear_lod_meshes()
	if data:
		for ck in data.get_loaded_chunk_keys():
			data.mark_chunk_dirty(ck)
	request_update()

## 粒子点数上限。
@export_range(100, 500000, 100) var particle_max_points: int = 200000

## 只渲染表面体素（跳过被完全包住的）。
@export var particle_surface_only: bool = true

## 自发光强度倍率，与网格路径的 MATERIAL_EMISSION_ENERGY 同量级（= 20）。
@export_range(0.0, 100.0, 0.5) var particle_emission_energy: float = 20.0

## 粒子（体素方块）的显示尺寸倍率：1.0 = 与体素等比，拼起来严丝合缝。
@export_range(0.05, 3.0, 0.01) var particle_scale: float = 1.0

## 粒子整体透明度（出场/退场淡出用）。
@export_range(0.0, 1.0, 0.01) var particle_alpha: float = 1.0

## 按空间（Morton / Z-order）顺序重排点云后再上传（点云内容旋钮，改完需 `rebuild_particles()`）。
@export var particle_spatial_sort: bool = false

# [INF] 视点相关

## 视点层组件：视锥剔除 / 延迟补建队列 / 流式加载与卸载 / LOD 粗层调度 / 原点漂移。
var view_layer: VoxelViewLayer = null:
	set(v):
		if view_layer == v:
			return
		view_layer = v
		# 换/摘视点层会让全部分带的语义改变：分带表由它维护，网格账本层数随之对齐。
		_configure_lod()
		request_update()

## 可见性管理模式（决定哪些 chunk 生成网格）
enum VisibilityMode {
	FULL,      ## 全量生成所有 chunk（简单，适合中小世界，内存随世界线性增长）
	FRUSTUM,   ## 视锥剔除：仅生成视锥内（或 view_distance 内）的 chunk，进视锥再补建
	STREAMING, ## 流式加载：按距离生成 + 卸载，远距 chunk 网格释放（适合超大型世界）
}

## 绘制模式：决定"体素几何怎么变成绘制单元"。
enum DrawMode {
	STATIC,   ## 全部合并成 1 个 mesh / ≤2 个 surface。静态道具、建筑、只读展示（**默认**）。
	DYNAMIC,  ## 每 group 一个 MeshInstance3D。可破坏、可逐体素编辑、水模拟。
}

## 体素数据资源
@export var data: QVoxelSource:
	set(v):
		# setter 内部赋值不会递归，可直接设置底层存储
		if data and data.changed.is_connected(_on_data_changed):
			data.changed.disconnect(_on_data_changed)
		data = v
		if data:
			data.changed.connect(_on_data_changed)
		_materials.invalidate()
		_configure_lod()
		_clear_lod_meshes()
		request_update()

## 绘制模式。
@export var draw_mode: DrawMode = DrawMode.STATIC:
	set(v):
		if draw_mode == v:
			return
		draw_mode = v
		_clear_lod_meshes()
		mesh = null
		request_update()

## DYNAMIC 模式的分组粒度（= 每组 2^group_shift 个 chunk 的边长）。
@export_range(0, 2, 1) var group_shift: int = 0:
	set(v):
		group_shift = clampi(v, 0, 2)
		_clear_lod_meshes()
		request_update()

## DYNAMIC 模式的分组账本：group_key → MeshInstance3D。
var _group_meshes: Dictionary = {}
## DYNAMIC 分组路径的待重建组集合（group_key → true）。
var _group_dirty: Dictionary = {}
## 【分组模式的核心缓存】chunk_key → 该 chunk 的几何数组（worker 在子线程产出）。
var _chunk_arrays: Dictionary = {}

## 体素缩放比例 (单个体素的边长，世界单位)
@export var voxel_scale: float = 0.1:
	set(v):
		voxel_scale = v
		# Voxel scale 变化会影响 chunk mesh 的位置，需要重建。
		if not _lod_meshes.is_empty() and not _lod_meshes[0].is_empty():
			_clear_lod_meshes()
		request_update()
		if display_mode == DisplayMode.PARTICLES:
			rebuild_particles()

## 数据变化时是否自动重新生成 mesh
@export var auto_update: bool = true

## 重建限流帧数：一帧内多次数据变化会被合并，最多每 N 帧重建一次 mesh
@export_range(1, 30) var update_throttle_frames: int = 1

# [INF] 视点相关
@export var visibility_mode: VisibilityMode = VisibilityMode.FRUSTUM:
	set(v):
		visibility_mode = v
		# 视点层一律被通知（它读 visibility_mode 来决定过滤/流式行为；FULL 下清空延迟队列）。
		if view_layer != null:
			view_layer.on_visibility_mode_changed(v)
		if v == VisibilityMode.FULL:
			# 全量模式下补建已加载 chunk 的网格（卸载的由统一流式按需重载）
			if data:
				for ck in data.get_loaded_chunk_keys():
					data.mark_chunk_dirty(ck)
		request_update()
		# 可见性变化影响多个属性的有效性 → 刷新 Inspector（隐藏/显示条件属性）
		notify_property_list_changed()

# [INF] 视点相关
func _validate_property(property: Dictionary) -> void:
	var name: StringName = property["name"]
	var hide := false
	match name:
		&"view_distance", &"unload_distance", &"lod_count":
			# FULL 全量模式不走流式/LOD，距离参数无效
			hide = visibility_mode == VisibilityMode.FULL
		&"_collision_rebuild_per_frame":
			# 碰撞重建限速仅开启碰撞（generate_collision）时生效
			hide = not generate_collision
	if hide:
		property["usage"] = int(property["usage"]) & ~PROPERTY_USAGE_EDITOR

# [INF] 视点相关
@export var view_distance: float = 40.0:
	set(v):
		view_distance = v
		# 视点层的分带表由它自己按 (lod_count, view_distance) 重算（唯一真值）
		_configure_lod()

# [INF] 视点相关
@export var unload_distance: float = 0.0

# [INF] 视点相关
@export_range(1, 8, 1) var lod_count: int = 1:
	set(v):
		lod_count = clampi(v, 1, 8)
		_configure_lod()
		notify_property_list_changed()

# [INF] 视点相关
@export_range(1, 120) var visibility_check_interval: int = 8

# ── LOD 网格账本（渲染层）────────────────────────────────────────────────────
var _lod_meshes: Array[Dictionary] = [{}]

# LOD 大块（godot_voxel 风格大 block）：GRID³ 大格，每格 = 2^level 体素。
const LOD_GRID := VoxelLodGrid.GRID

## 见 VoxelLodGrid.block_edge_world（本类挂载节点与 origin shift 需要层边长）
func _lod_block_edge_world(level: int) -> float:
	return VoxelLodGrid.block_edge_world(level, voxel_scale)

# 【LOD 调度旋钮不在这里】build_per_frame / preload_blocks / build_budget_ms /
func _configure_lod() -> void:
	# 分带计算 + 调度表长度对齐都归视点层：它持调度表、本类持网格账本 `_lod_meshes`，
	if view_layer != null:
		view_layer.sync_lod_levels()
	if data:
		data.lod_count = lod_count
		if lod_count <= 1:
			data.clear_lod_cache()
	request_update()

## 对齐本类网格账本 `_lod_meshes` 的层数（由视点层的 sync_lod_levels 驱动）。
func set_lod_level_count(n: int) -> void:
	while _lod_meshes.size() > n:
		clear_lod_level(_lod_meshes.size() - 1)
		_lod_meshes.pop_back()
	while _lod_meshes.size() < n:
		_lod_meshes.append({})
	# 材质对齐数组随层数同步（唯一缓存在 _materials 内，不再逐层单独维护）
	_materials.set_level_count(n)

## 释放指定 LOD 层级的全部网格节点（粗层的调度账本归视点层，由它自己 pop 掉）
func clear_lod_level(level: int) -> void:
	if level < 0 or level >= _lod_meshes.size():
		return
	for bk in _lod_meshes[level]:
		var mi = _lod_meshes[level][bk]
		if mi != null and is_instance_valid(mi):
			mi.queue_free()
	_lod_meshes[level].clear()

## 是否生成静态碰撞体 (StaticBody3D + ConcavePolygonShape3D)
@export var generate_collision: bool = false:
	set(v):
		generate_collision = v
		collision.enabled = v
		if not v:
			collision.clear_all()
		request_update()
		notify_property_list_changed()

## 碰撞组件（懒创建的子节点）。
var collision: VoxelCollision:
	get:
		if _collision == null:
			_collision = VoxelCollision.new()
			_collision.name = "Collision"
			_collision.collision_layer = collision_layer
			_collision.collision_mask = collision_mask
			_collision.rebuild_per_frame = _collision_rebuild_per_frame
			_collision.rebuild_budget_ms = collision_rebuild_budget_ms
			_collision.enabled = generate_collision
			add_child(_collision)
			_collision.configure(self)
		return _collision

var _collision: VoxelCollision = null

## 碰撞体所属物理层（透传给 VoxelCollision）
@export_flags_3d_physics var collision_layer: int = 1:
	set(v):
		collision_layer = v
		if _collision != null:
			_collision.collision_layer = v

## 碰撞体检测的物理层（透传给 VoxelCollision）
@export_flags_3d_physics var collision_mask: int = 1:
	set(v):
		collision_mask = v
		if _collision != null:
			_collision.collision_mask = v

## 是否在编辑器中也实时更新 (仅 @tool 模式)
@export var update_in_editor: bool = true

## 诊断模式开关：开启后在输出面板打印详细的网格重建日志，用于定位性能瓶颈
@export var diag_enabled: bool = false

var _dirty: bool = false
## 材质唯一缓存：快照 / 运行时材质 / 各层对齐数组三份派生都在它内部，失效只有 invalidate() 一个入口
var _materials := VoxelMaterialCache.new()
var _update_counter: int = 0

# 【流式限量旋钮已搬进 VoxelViewLayer】stream_load_per_frame /…
var _batch: VoxelMeshBatch = null
var _exiting := false                    # 退出中：worker 结果回调据此直接丢弃，避免访问已清理数据
# 异步任务运行期间收到新变更时置位，任务完成后重新触发更新（保证数据始终最新且不并发）
var _pending_retrigger: bool = false
# 批次全部完成待处理标志：置位后下一帧 _process 执行 _on_batch_complete（避免主线程尖峰）
var _batch_complete_pending: bool = false
# Per-chunk 模式：每个非空 chunk 对应一个子 MeshInstance3D（LOD0 网格存于 _lod_meshes[0]）
@export_range(1, 100, 1) var _collision_rebuild_per_frame: int = 12:
	set(v):
		_collision_rebuild_per_frame = v
		if _collision != null:
			_collision.rebuild_per_frame = v
## 每帧碰撞重建的时间预算（毫秒）。
@export_range(0.0, 100.0, 0.5) var collision_rebuild_budget_ms: float = 4.0:
	set(v):
		collision_rebuild_budget_ms = v
		if _collision != null:
			_collision.rebuild_budget_ms = v

# GPU 上传限流队列：异步结果先缓存数组数据，_process 帧尾批量构建 mesh（平滑 GPU 上传，
var _mesh_build_queue: Dictionary = {}
# 每帧最多构建的 chunk 数（GPU 上传限流）
@export_range(1, 100, 1) var _mesh_build_per_frame: int = 12
# 增量重建每帧最多处理的 dirty chunk 数：超出放回下帧续建（防回原点/大崩塌单帧
@export_range(8, 512, 8) var _rebuild_batch_limit: int = 64 * 4096 / VoxelChunk.CHUNK_VOLUME

# 帧尾构建是否已排期（防重复 call_deferred）
var _mesh_build_scheduled: bool = false

## 最近一次网格生成耗时（毫秒），供外部 HUD 等调试显示
var last_mesh_gen_time_ms: float = 0.0

## 性能追踪：上次生成的顶点数/三角形数
var last_solid_vertices: int = 0
var last_solid_triangles: int = 0
var last_trans_triangles: int = 0
var last_total_chunks: int = 0

## 性能追踪：最近一次重建的 chunk 数量与耗时明细
var last_rebuild_chunk_count: int = 0
var last_mesh_gen_time_slice_ms: float = 0.0  ## 生成阶段耗时（不含 apply）
var last_apply_time_ms: float = 0.0        ## 应用到场景的耗时 (ms)

## 本批异步结果的累加器（批起点：_update_mesh_async 建 VoxelMeshBatch 处清零）
var _batch_rebuilt_chunks: int = 0

func _ready() -> void:
	_configure_lod()
	request_update()
	# 【不要在这里加"GPU 忙检测"】若真要做，判据必须是"上一帧实际耗时"而不是
	if view_layer != null:
		view_layer.on_visibility_mode_changed(visibility_mode)
		view_layer.sync_lod_levels()

func _process(_delta: float) -> void:
	# 【STATIC = 真的最简：整段视点调度直接跳过】
	if draw_mode == DrawMode.STATIC:
		_drive_static()
		return
	_process_dynamic_body()

## STATIC 模式的每帧驱动：只有"脏了才重建"，别的什么都不做。
func _drive_static() -> void:
	if not (_dirty and auto_update and (not Engine.is_editor_hint() or update_in_editor)):
		return
	_update_counter += 1
	if _update_counter < update_throttle_frames:
		return
	_update_counter = 0
	_update_mesh()

## DYNAMIC 模式的每帧驱动：视点调度 + GPU 上传限流 + 碰撞限流 + 异步批次收尾。
func _process_dynamic_body() -> void:

	# 可见性管理（每帧限量执行，走近/远离平滑）。
	if view_layer != null:
		if visibility_mode != VisibilityMode.FULL:
			view_layer.process_deferred_chunks()
		# 统一流式/程序化驱动：是否真的跑由视点层内部按 data.is_streaming() 判定
		view_layer.process_streaming()
		# LOD 管理：每 interval 帧限量生成/移除（降低每帧遍历开销，近处 LOD0 / 远处各粗层互补）。
		view_layer.process_lod()

	# GPU 上传限流：帧尾批量构建队列中的 chunk mesh（避免与渲染/崩塌竞争 GPU）
	if (not _mesh_build_queue.is_empty() or not _group_dirty.is_empty()) and not _mesh_build_scheduled:
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")
	# 粗 LOD 大块 mesh 挂载同样帧尾限量（大块 mesh 覆盖数十万体素，GPU 上传昂贵）。
	if view_layer != null and view_layer.take_lod_mesh_flush_request():
		call_deferred("_flush_lod_mesh_apply_queue")

	# 碰撞增量重建已下沉到 VoxelCollision 组件（它有自己的 _process 与双限流），

	# 延迟批次完成：全部异步任务完成后，在下一帧处理剩余收尾逻辑，避免主线程尖峰
	if _batch_complete_pending:
		_batch_complete_pending = false
		_on_batch_complete()

	if not (_dirty and auto_update and (not Engine.is_editor_hint() or update_in_editor)):
		return
	# 限流：合并帧内多次变更，最多每 update_throttle_frames 帧重建一次
	_update_counter += 1
	if _update_counter < update_throttle_frames:
		return
	_update_counter = 0

	# 若有尚未完成的批次，不启动新批次：批次的脏体素在其派发时已被清除，
	if _batch != null and _batch.is_active():
		_pending_retrigger = true
		return

	_update_mesh()

# ── 粒子渲染：公开接口（实现已下沉到 VoxelParticleView 组件）──────────────

## 粒子视图组件（懒创建的子节点）。
var particle_view: VoxelParticleView:
	get:
		if _particle_view == null:
			_particle_view = VoxelParticleView.new()
			_particle_view.name = "Particles"
			_sync_particle_view_config()
			add_child(_particle_view)
			_particle_view.configure(self)
		return _particle_view

var _particle_view: VoxelParticleView = null

## 把本类的粒子旋钮推给组件（本类是 Inspector 唯一真值，组件只读）。
func _sync_particle_view_config() -> void:
	if _particle_view == null:
		return
	_particle_view.max_points = particle_max_points
	_particle_view.surface_only = particle_surface_only
	_particle_view.emission_energy = particle_emission_energy
	_particle_view.particle_scale = particle_scale
	_particle_view.alpha = particle_alpha
	_particle_view.voxel_shape = int(voxel_shape)
	_particle_view.sphere_scale = sphere_scale
	_particle_view.sphere_subdivisions = sphere_subdivisions
	_particle_view.spatial_sort = particle_spatial_sort

## 重新导出点云并重建 GPU 资源（转发给组件）。
func rebuild_particles() -> void:
	_sync_particle_view_config()
	particle_view.rebuild()

## 粒子方块的边长（世界单位）= 体素边长 × particle_scale。
func particle_voxel_size() -> float:
	return voxel_scale * particle_scale

## 粒子节点（转发组件的公开字段；项目可自己换 process_material 做运动效果）。
var particle_node: GPUParticles3D:
	get:
		return _particle_view.particle_node if _particle_view != null else null

## 最近一次导出的点数据（转发组件的公开字段）。
var particle_points: PackedFloat32Array:
	get:
		return _particle_view.particle_points if _particle_view != null else PackedFloat32Array()

# ── 粒子渲染：内部（可见性协调，网格与粒子互斥）────────────────────────────

## 网格此刻是否应当可见（粒子模式下网格必须整体隐藏）。
func _meshes_should_be_visible() -> bool:
	return display_mode != DisplayMode.PARTICLES

func _apply_display_mode() -> void:
	var use_particles := display_mode == DisplayMode.PARTICLES
	if _particle_view != null and _particle_view.particle_node != null:
		_particle_view.particle_node.visible = use_particles
	# 粒子模式下隐藏网格：两条路径画的是同一份数据，同屏会互相穿插
	for lod in _lod_meshes:
		for bk in lod:
			var mi = lod[bk]
			if mi is Node3D:
				(mi as Node3D).visible = not use_particles
	for gn in _group_meshes.values():
		if gn != null and is_instance_valid(gn):
			(gn as Node3D).visible = not use_particles
	if mesh != null:
		# STATIC 的几何挂在本节点自己身上（self.mesh），粒子模式下要整体隐藏
		visible = not use_particles
	if use_particles and (_particle_view == null or _particle_view.particle_node == null) and data != null:
		rebuild_particles()

func _on_data_changed() -> void:
	# STATIC 下所有挂在同一份 data 上的实例会同时收到本信号。
	if draw_mode == DrawMode.STATIC:
		VoxelMesher.invalidate_shared_mesh(data)
	request_update()
	# 粒子模式下数据变了要重导点云（网格那套脏账本对点云不适用：
	if display_mode == DisplayMode.PARTICLES:
		rebuild_particles()

func request_update() -> void:
	_dirty = true

## 标记为脏，下一帧自动更新 (若 auto_update=true)
func mark_dirty() -> void:
	request_update()

## 立即强制重新生成 mesh
func force_update() -> void:
	_dirty = true
	if _batch != null and _batch.is_active():
		_pending_retrigger = true
		return
	_dirty = false
	_update_mesh()

## 强制重新生成纹理材质 (材质属性变化时调用)
func regenerate_materials() -> void:
	# 三份派生一起作废。
	_materials.invalidate()
	request_update()

## 获取当前体素数据
func get_data() -> QVoxelSource:
	return data

## 当前渲染相机（未入树 / 无相机时为 null）。
func current_camera() -> Camera3D:
	return get_viewport().get_camera_3d() if is_inside_tree() else null

## chunk 是否已有渲染网格（"我的体素已经画出来了"）。
func has_chunk_mesh(ck: Vector3i) -> bool:
	if draw_mode == DrawMode.STATIC:
		return mesh != null
	if group_shift > 0:
		var gn: MeshInstance3D = _group_meshes.get(VoxelMesher.group_of(ck, group_shift))
		return gn != null and is_instance_valid(gn) and gn.mesh != null
	return not _lod_meshes.is_empty() and _lod_meshes[0].has(ck)

## 该 chunk 的渲染网格节点（碰撞 / 组件按 chunk 定位网格时用）。
func chunk_mesh(ck: Vector3i) -> MeshInstance3D:
	if draw_mode == DrawMode.STATIC:
		return self if mesh != null else null
	if group_shift > 0:
		var gn: MeshInstance3D = _group_meshes.get(VoxelMesher.group_of(ck, group_shift))
		return gn if gn != null and is_instance_valid(gn) else null
	return _lod_meshes[0].get(ck) if not _lod_meshes.is_empty() else null

## LOD 层数（含 LOD0），= 网格账本 `_lod_meshes` 的长度。
func lod_level_count() -> int:
	return _lod_meshes.size()

## 设置指定位置体素 (会触发自动更新)
func set_voxel(pos: Vector3i, material_id: int) -> void:
	if data:
		data.set_voxel(pos, material_id)

## 移除指定位置体素 (会触发自动更新)
func remove_voxel(pos: Vector3i) -> void:
	if data:
		data.remove_voxel(pos)

## 获取指定位置体素材质ID
func get_voxel(pos: Vector3i) -> int:
	if data:
		return data.get_voxel(pos)
	return -1

## 入树可能只是"临时挪窝"（reparent）后又回来：_exit_tree 已置 _exiting 并清了网格。
func _enter_tree() -> void:
	_exiting = false
	if data != null:
		request_update()

func _exit_tree() -> void:
	# 退出：等待所有 worker 任务完成后再释放，否则 worker 完成时 call_deferred
	_exiting = true
	_cancel_async()
	# 粗层 worker 的任务 ID 与在途状态都在视点层，由它统一置停 + wait（必须在释放节点前）。
	if view_layer != null:
		view_layer.abort()
	_clear_lod_meshes()

# [INF] 视点相关
func _cancel_async() -> void:
	# 【必须先取局部引用】Signal 的 emit 是**同步**的：cancel() 内部 _finish() 会 emit
	var batch := _batch
	if batch == null:
		return
	batch.cancel()
	batch.wait_tasks()
	_batch = null

func _update_mesh() -> void:
	_dirty = false
	if not data:
		_cancel_async()
		mesh = null
		_clear_lod_meshes()
		mesh_updated.emit()
		return

	# 【唯一的分叉】绘制模式决定走哪条路径。
	if draw_mode == DrawMode.STATIC:
		# STATIC 不预先派生材质快照：它走共享缓存，材质只由**第一个**构建者生成一次
		_rebuild_static()
		return

	# DYNAMIC：纹理材质与材质快照都走唯一缓存（材质变化时需手动调用 regenerate_materials 作废）：
	_materials.surfaces(data.materials)
	_materials.snapshot(data.materials)
	# 统一走异步生成（CHUNK_ASYNC 为唯一路径，不要加回同步路径）
	_update_mesh_async()

## STATIC 模式：整份模型 → 1 个 ArrayMesh（≤2 surface）挂在本节点自己的 mesh 上。
func _rebuild_static() -> void:
	_cancel_async()          # STATIC 不用异步批次，清掉可能残留的 DYNAMIC 任务
	# 【为什么用 Dictionary 接住而不是普通局部变量】GDScript 的 lambda **按值捕获**局部变量，
	var holder := {"arrays": {}} 
	var cached := VoxelMesher.acquire_shared_mesh(data, voxel_scale, func() -> ArrayMesh:
		var bufs: Dictionary = data._chunk_buffers_view()
		var arrays := VoxelMesher.build_all(bufs, data.materials, voxel_scale, data.center_offset)
		holder["arrays"] = arrays
		var mats := _materials.surfaces(data.materials)
		return VoxelMesher.to_mesh(arrays, mats))
	mesh = cached
	var built_arrays: Dictionary = holder["arrays"]
	if mesh != null and not built_arrays.is_empty():
		# 【不要用 surface_get_arrays 数三角形】它会为整个 surface 复制一份新字典
		var solid_v := (built_arrays.get("solid_verts", PackedVector3Array()) as PackedVector3Array).size()
		var trans_v := (built_arrays.get("trans_verts", PackedVector3Array()) as PackedVector3Array).size()
		# 【为什么用 chunk_count() 而不是 get_all_chunk_keys().size()】后者为了数一个数字，
		_set_last_vertex_stats(solid_v, trans_v, data.chunk_count())
	# 【STATIC 也要碰撞】整份模型是**一个**绘制单元，交给碰撞组件按单元重建（它自己限量）。
	collision.enqueue(Vector3i.ZERO, mesh != null)
	mesh_updated.emit()

## 相机到 chunk 中心的距离（统一实现见 VoxelWorldUtil）。
static func _chunk_center_dist(ck: Vector3i, cam_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> float:
	return VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset)

static func _is_chunk_beyond_unload(ck: Vector3i, cam: Camera3D, chunk_size_world: float, world_offset: Vector3, unload_d: float) -> bool:
	if cam == null or unload_d <= 0.0:
		return false
	return _chunk_center_dist(ck, cam.global_position, chunk_size_world, world_offset) > unload_d

## origin shift 后平移**渲染层**：所有网格节点 key 平移 + 节点 position 更新 + 各类集合字典 key…
func shift_render(shift: Vector3i, chunk_size_world: float) -> void:
	var new_lod0: Dictionary[Vector3i, MeshInstance3D] = {}
	for ck in _lod_meshes[0]:
		var nck: Vector3i = ck + shift
		var mi: MeshInstance3D = _lod_meshes[0][ck]
		if mi != null:
			mi.position = Vector3(nck) * chunk_size_world
		new_lod0[nck] = mi
	_lod_meshes[0] = new_lod0
	# 各粗 LOD 层网格节点平移（每层 block 边长不同）
	for level in range(1, _lod_meshes.size()):
		var edge_world := _lod_block_edge_world(level)
		var new_c: Dictionary = {}
		for bk in _lod_meshes[level]:
			var nbk: Vector3i = bk + shift
			var mi = _lod_meshes[level][bk]
			if mi != null:
				mi.position = Vector3(nbk) * edge_world
			new_c[nbk] = mi
		_lod_meshes[level] = new_c
	# 各类 chunk/block 集合字典 key 整体平移（统一实现见 VoxelChunk.shift_key_dict；
	_mesh_build_queue = VoxelChunk.shift_key_dict(_mesh_build_queue, shift)
	# 分组账本与 chunk 几何缓存同样按键平移（不平移会让在途组指向旧坐标）
	if group_shift > 0:
		_group_meshes = VoxelChunk.shift_key_dict(_group_meshes, shift)
		_group_dirty = VoxelChunk.shift_key_dict(_group_dirty, shift)
	_chunk_arrays = VoxelChunk.shift_key_dict(_chunk_arrays, shift)
	# 碰撞账本归协作组件：它自己的键与节点位置由它按同一个 shift 平移。
	if _collision != null:
		_collision.on_origin_shift(shift, chunk_size_world)
	# 子类钩子：本类只平移**渲染层**状态。
	on_origin_shift(shift)

## origin shift 完成后的子类钩子（默认空实现）。
func on_origin_shift(_shift: Vector3i) -> void:
	pass

# 多层级 LOD 渲染（lod_count 控制层级数，view_distance 自动等比 ×2 分带）

# ── LOD 网格账本 API（视点层经此读写）────────────────────────────────────────

## 该层该 block 是否有条目（含"空标记"null —— 表示确定无体素、停止重复派发）
func has_lod_mesh(level: int, bk: Vector3i) -> bool:
	return level >= 0 and level < _lod_meshes.size() and _lod_meshes[level].has(bk)

## 取该层该 block 的网格节点；返回 null = 无条目或"空标记"（判定"是否已就绪"时两者同义）
func lod_mesh(level: int, bk: Vector3i) -> MeshInstance3D:
	if level < 0 or level >= _lod_meshes.size():
		return null
	return _lod_meshes[level].get(bk)

## 该层全部 block key 快照（视点层遍历用）。
func lod_mesh_keys(level: int) -> Array:
	if level < 0 or level >= _lod_meshes.size():
		return []
	return _lod_meshes[level].keys()

## 标记该 block"确定空"（无体素）：保留条目但置 null
func mark_lod_block_empty(level: int, bk: Vector3i) -> void:
	if level >= 0 and level < _lod_meshes.size():
		_lod_meshes[level][bk] = null

## 主线程挂载粗 LOD 大块网格（mesh 已由工作线程构建，此处仅建节点 + 挂载，很轻）
func mount_lod_mesh(level: int, bk: Vector3i, mesh: ArrayMesh) -> void:
	if level < 0 or level >= _lod_meshes.size():
		return
	var mi: MeshInstance3D = _lod_meshes[level].get(bk)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "LOD%dB_%d_%d_%d" % [level, bk.x, bk.y, bk.z]
		add_child(mi)
		# 新建的节点默认可见 —— 粒子模式下必须立刻隐藏，否则会和粒子同屏
		mi.visible = _meshes_should_be_visible()
		mi.position = Vector3(bk) * _lod_block_edge_world(level)
	if mesh != null and mesh.get_surface_count() > 0:
		mi.mesh = mesh
	_lod_meshes[level][bk] = mi

## 释放某层某 block 的网格节点并移除条目（粗层的调度账本归视点层，由它自己清）
func clear_lod_mesh(level: int, bk: Vector3i) -> void:
	if level < 1 or level >= _lod_meshes.size():
		return
	var mi = _lod_meshes[level].get(bk)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[level].erase(bk)

## 该 chunk 是否在构建队列中（视点层判定"内层是否就绪"用）
func is_mesh_build_queued(ck: Vector3i) -> bool:
	return _mesh_build_queue.has(ck)

## 取（必要时重建）某 LOD 层的材质对齐数组：层级 → 体素材质 id 数组
func lod_materials(level: int, force: bool = false) -> Array:
	if data == null:
		return []
	if force:
		return _materials.rebuild_aligned(data.materials, level)
	# 走 aligned_shared：返回内部缓存那份数组本身（不拷贝）。
	return _materials.aligned_shared(data.materials, level)

## 取渲染用的运行时 Material 对象数组（表面 0/1）。
func surface_materials() -> Array:
	return _materials.surfaces(data.materials) if data else []

## 清除单个 chunk 的渲染网格（释放 mesh + 碰撞 + 相关队列条目）。
func remove_chunk_mesh(ck: Vector3i) -> void:
	var mi: MeshInstance3D = _lod_meshes[0].get(ck)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[0].erase(ck)
	if _collision != null:
		_collision.remove(ck)
	_mesh_build_queue.erase(ck)
	# 【分组模式的几何缓存必须一起淘汰】_chunk_arrays 是"worker 产出的该 chunk 数组"，
	_chunk_arrays.erase(ck)
	# 该 chunk 的重建权随网格移除作废（否则延迟队列里残留"幽灵补建"条目）
	if view_layer != null:
		view_layer.on_mesh_removed(ck)

## 异步路径：后台线程生成网格数据，完成后通过 call_deferred 直接传递结果到主线程
func _update_mesh_async() -> void:
	# 若旧任务已完成但还未轮询应用（极端情况），不阻塞，直接启动新任务覆盖

	# 【密集光环快照方案】不为每个 chunk 提取字典切片，而是让 QVoxelSource 直接从其
	var rebuild_chunks: Array[Vector3i] = []
	# chunk 级脏标记（_mark_voxel_dirty 已含跨界面的边界邻居）：
	rebuild_chunks = data.get_dirty_chunks()
	var had_dirty := not rebuild_chunks.is_empty()
	# 【防闪】剔除"源已作废、等待重新取数"的 chunk：作废后其缓冲为空，拿空快照重建会把
	if not rebuild_chunks.is_empty():
		var keep: Array[Vector3i] = []
		for ck in rebuild_chunks:
			if not data._is_chunk_source_invalidated(ck):
				keep.append(ck)
		rebuild_chunks = keep
	# 【流式防抖】剔除已在延迟补建队列的脏 chunk：其重建权归视点层的延迟队列
	var dropped := 0
	if view_layer != null and not view_layer.deferred_is_empty():
		for i in range(rebuild_chunks.size() - 1, -1, -1):
			if view_layer.is_deferred(rebuild_chunks[i]):
				rebuild_chunks.remove_at(i)
				dropped += 1
	if diag_enabled and dropped > 0:
		print("[诊断] 增量重建防抖: 剔除已在延迟队列的脏 chunk %d 个" % dropped)
	# 限量批次：超过上限的放回 dirty（下帧续建）。
	if rebuild_chunks.size() > _rebuild_batch_limit:
		for i in range(_rebuild_batch_limit, rebuild_chunks.size()):
			data.mark_chunk_dirty(rebuild_chunks[i])
		rebuild_chunks.resize(_rebuild_batch_limit)
		# 放回剩余 dirty 后必须重新置位：_update_mesh 开头会清 _dirty，
		request_update()
	# 有脏标记但全部已在延迟队列 → 本帧无生产性工作：不递增 gen_id、不派发任务、
	if rebuild_chunks.is_empty() and had_dirty:
		return
	# 材质快照复用缓存（仅在材质变化时深拷贝），避免每帧大对象深拷贝
	var snapshot_materials := _materials.snapshot(data.materials)
	# 一次对齐材质供所有 per-chunk worker 复用，避免每个任务重复 align_by_id
	var aligned_materials := VoxelMaterial.align_by_id(snapshot_materials)
	# 透明标志表按批次算一次（逐块重建要扫一遍材质表，批量重建时纯属重复劳动）
	var trans_flags := VoxelMaterial.build_trans_flags(aligned_materials)
	# 渲染居中偏移（体素单位），子线程无权访问节点，随任务参数传入
	var render_offset: Vector3 = data.center_offset if data else Vector3.ZERO

	# 后台线程生成纯数据（线程安全，不触碰 ArrayMesh）
	var visible: Array[Vector3i]
	if rebuild_chunks.is_empty():
		# 全量构建（初始构建或切换模式后）：分 chunk 独立线程，逐个显示
		var all_chunks := data.get_all_chunk_keys()
		if all_chunks.is_empty():
			# 空场景：无 chunk 可生成，直接返回（无任务，pending 保持 0）
			return
		# 统一可见性决策（流式距离 + 视锥/近处全向）
		visible = _filter_visible(all_chunks)
		if diag_enabled:
			print("[诊断] 全量构建: 总%d Chunk, 视锥内%d, 延迟%d" % [all_chunks.size(), visible.size(), all_chunks.size() - visible.size()])
	else:
		# 增量重建：每个 chunk 独立一个线程任务，真正并行处理
		for ck in rebuild_chunks:
			if _lod_meshes[0].has(ck) and not data.has_chunk(ck):
				remove_chunk_mesh(ck)
		# 统一可见性决策（流式距离 + 视锥/近处全向）
		visible = _filter_visible(rebuild_chunks)
		if diag_enabled:
			print("[诊断] 增量重建: 脏%d Chunk, 视锥内%d, 延迟%d" % [rebuild_chunks.size(), visible.size(), rebuild_chunks.size() - visible.size()])
	# 本帧渲染批次：任务计数与只读快照句柄都由它持有，结算点唯一（见 VoxelMeshBatch）。
	var batch := VoxelMeshBatch.new()
	batch.result_ready.connect(_on_batch_result.bind(batch))
	batch.finished.connect(_on_batch_finished.bind(batch))
	_batch = batch
	# 批起点清零重建计数：对外表示"最近一（批）次重建做了多少"，不清零就会跨批累加成
	_batch_rebuilt_chunks = 0
	# 快照预算：超预算尾部放回 dirty 下帧续建（_update_mesh 开头清 _dirty，须重置位），
	if data and not visible.is_empty():
		batch.attach_snapshot(data.begin_readonly_snapshot())
	var snap := _snapshot_budgeted(visible)
	var snapshot: Dictionary = snap["snapshot"]
	var taken: int = snap["taken"]
	if taken < visible.size():
		for j in range(taken, visible.size()):
			data.mark_chunk_dirty(visible[j])
		request_update()
		visible.resize(taken)
	# 【为什么先捕获成局部】worker 在子线程执行，约定是"只读参数、不碰节点属性"。
	var w_scale := voxel_scale
	var w_offset := render_offset
	var w_diag := diag_enabled
	# 形状参数同样按值捕获（worker 不能读节点属性）
	var w_shape := int(voxel_shape)
	var w_subdiv := sphere_subdivisions
	var w_sphere_scale := sphere_scale
	for ck in visible:
		# 【必须用 lambda 显式绑定 out 的位置】Godot 4 的 Callable.bind() 把绑定实参放在
		batch.spawn(func(out: Dictionary) -> void:
			_generate_chunk_worker(snapshot, aligned_materials, trans_flags, ck,
				w_scale, w_offset, w_diag, out, w_shape, w_subdiv, w_sphere_scale))
	# 一个任务都没派发出去时必须立即结算：否则 _batch 永远"在途"，会挡住后续所有更新
	batch.settle_if_idle()

## 可见 chunk halo 快照的每帧毫秒预算：常规 6ms；可见集超过 _rebuild_batch_limit 时放宽到 10ms
const _SNAPSHOT_BUDGET_MS := 6.0
const _SNAPSHOT_BUDGET_MS_LARGE := 10.0

## 可见 chunk 的 halo 快照（毫秒预算版）：逐片快照、超预算即止。
func _snapshot_budgeted(visible: Array[Vector3i]) -> Dictionary:
	var budget_ms := _SNAPSHOT_BUDGET_MS
	if visible.size() > _rebuild_batch_limit:
		budget_ms = _SNAPSHOT_BUDGET_MS_LARGE
	var t0 := Time.get_ticks_usec()
	var snapshot: Dictionary = {}
	var taken := 0
	while taken < visible.size():
		var endi := mini(taken + 4, visible.size())
		snapshot.merge(data._snapshot_chunks_halo(visible.slice(taken, endi)))
		taken = endi
		if taken < visible.size() and (Time.get_ticks_usec() - t0) / 1000.0 > budget_ms:
			break
	return {snapshot = snapshot, taken = taken}

## 统一工作线程结果字典契约（#6）：全量/增量/单chunk/空场景所有生成路径
static func _make_result(arrays: Variant, gen_time_ms: float, solid_vertices: int,
		trans_vertices: int, total_chunks: int,
		chunk_key: Vector3i = Vector3i(-999, -999, -999)) -> Dictionary:
	return {
		"arrays": arrays,
		"chunk_key": chunk_key,
		"gen_time_ms": gen_time_ms,
		"solid_vertices": solid_vertices,
		"trans_vertices": trans_vertices,
		"total_chunks": total_chunks,
	}

## 以顶点计数更新 last_* 统计字段（实心/透明三角形 = 顶点数 / 3）
func _set_last_vertex_stats(solid_vertices: int, trans_vertices: int, total_chunks: int) -> void:
	last_solid_vertices = solid_vertices
	# trans_vertices 只在这里转成三角形数：不单独存一份顶点数（无读者，见字段注释）
	last_solid_triangles = solid_vertices / 3
	last_trans_triangles = trans_vertices / 3
	last_total_chunks = total_chunks

## 从统一结果字典更新 last_* 统计字段
func _apply_stats_from_result(result: Dictionary) -> void:
	last_mesh_gen_time_ms = result.get("gen_time_ms", 0.0) as float
	_set_last_vertex_stats(
		result.get("solid_vertices", 0),
		result.get("trans_vertices", 0),
		result.get("total_chunks", 0))

## 后台工作线程入口：生成网格数据并写入结果缓冲
func _generate_chunk_worker(buffers: Dictionary, materials: Array, trans_flags: PackedByteArray,
		chunk_key: Vector3i, scale: float, offset: Vector3 = Vector3.ZERO,
		diag_enabled: bool = false, out: Dictionary = {},
		shape: int = VoxelShape.CUBE, subdivisions: int = 0, sphere_scale_v: float = 1.0) -> void:
	var t0 := Time.get_ticks_usec()
	var halo := VoxelChunkGenerator.build_halo_from_buffers(buffers, chunk_key)
	var arr: Dictionary
	if shape == VoxelShape.SPHERE:
		# 球体路径：每体素一颗小球。
		arr = VoxelChunkGenerator.generate_spheres_for_chunk(
				halo, materials, scale, subdivisions, sphere_scale_v,
				VoxelChunkGenerator.SPHERE_VERTEX_BUDGET, offset)
	else:
		arr = VoxelChunkGenerator.generate_single_chunk_dense(
				halo, materials, scale, chunk_key, offset, trans_flags)
	var gen_time_ms := (Time.get_ticks_usec() - t0) / 1000.0

	# 诊断：每 chunk 生成耗时 > 5ms 时打印（仅诊断模式开启时）
	if diag_enabled and gen_time_ms > 5.0:
		print("[诊断] _generate_chunk_worker: Chunk%s, 总=%.2fms" % [chunk_key, gen_time_ms])

	# 统计顶点数
	var sv := 0
	var tv := 0
	var has_data := not arr.is_empty()
	if has_data:
		sv = arr.get("solid_verts", PackedVector3Array()).size()
		tv = arr.get("trans_verts", PackedVector3Array()).size()

	# 构建结果字典（统一契约 _make_result，含 chunk_key 供 _apply_single_chunk_result…
	var arrays := {}
	if has_data:
		arrays[chunk_key] = arr
	# 结果写进 out（由 VoxelMeshBatch 传入）：回传与计数结算都由批次负责。
	out.merge(_make_result(arrays, gen_time_ms, sv, tv, 1 if has_data else 0, chunk_key))

## 主线程结果处理入口（由 VoxelMeshBatch 在主线程发射）。
func _on_batch_result(result: Dictionary, batch: VoxelMeshBatch) -> void:
	if batch != _batch or _exiting:
		return
	var _diag_t0 := Time.get_ticks_usec()

	# 应用结果
	_apply_single_chunk_result(result)

	# 计数不在此处递减：结算点在 VoxelMeshBatch 内部唯一一处。
	var _t_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	if diag_enabled and _t_ms > 0.5:
		print("[诊断] _on_batch_result: 剩余%d任务, 应用耗时%.2f ms" % [batch.pending_count(), _t_ms])

## 批次结算（全部完成 / 被取消）：只读快照已由批次释放。
func _on_batch_finished(batch: VoxelMeshBatch) -> void:
	if batch != _batch:
		return
	_batch = null
	if batch.has_dispatched():
		_batch_complete_pending = true

## 应用单个 chunk 的异步结果（在主线程 _process 中调用）
func _apply_single_chunk_result(result: Dictionary) -> void:
	var _diag_t0 := Time.get_ticks_usec()
	var _t_get_chunk := 0.0
	var arrays = result.get("arrays", {})
	var chunk_key: Vector3i = result.get("chunk_key", Vector3i(-999, -999, -999))
	var gen_time_ms = result.get("gen_time_ms", 0.0) as float

	# 更新统计信息（统一契约 _apply_stats_from_result）
	_apply_stats_from_result(result)
	# 【按批累加】一个结果 = 一个 chunk 的重建量。
	_batch_rebuilt_chunks += 1
	last_rebuild_chunk_count = _batch_rebuilt_chunks

	# 单 chunk 结果（来自 _generate_chunk_worker）
	if chunk_key.x != -999:
		# 流式：结果回来时 chunk 仍超出卸载距离（相机快速远离）→ 丢弃过期结果，
		var cam_now := current_camera()
		if _is_chunk_beyond_unload(
				chunk_key, cam_now, voxel_scale * VoxelChunk.CHUNK_SIZE, global_position, _view_unload_d()):
			# 丢弃过期结果：计数由 VoxelMeshBatch 统一结算，这里直接返回即可
			return
		var arr = arrays.get(chunk_key, {})
		var has_voxels_in_data := false
		if data:
			var _t1 := Time.get_ticks_usec()
			has_voxels_in_data = data.has_chunk(chunk_key)
			_t_get_chunk = (Time.get_ticks_usec() - _t1) / 1000.0
		# 程序化生成：数据已被 LOD1 区释放（超 LOD0 区、由 LOD1 覆盖）→ 该异步结果过期丢弃。
		if data and data.node != null and not has_voxels_in_data:
			# 同上：结果过期丢弃，不碰计数
			return

		# 入队待构建（GPU 上传限流，_process 每帧批量处理）
		_mesh_build_queue[chunk_key] = {
			"arrays": arr if (arr is Dictionary and not arr.is_empty() and has_voxels_in_data) else {},
			"has_voxels": has_voxels_in_data,
		}
		# 统计字段就地写（原 _record_perf_stats 只剩这几行，且唯一调用点就在此处）：
		last_mesh_gen_time_slice_ms = gen_time_ms

	# 诊断：单 chunk 应用耗时 > 1ms 时打印（顺带把实测应用耗时写进公开统计字段）
	var _t_apply_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	last_apply_time_ms = _t_apply_ms
	if diag_enabled and _t_apply_ms > 1.0 and chunk_key.x != -999:
		print("[诊断] _apply_single_chunk_result: Chunk%s, get_chunk=%.2fms, 总=%.2fms" % [chunk_key, _t_get_chunk, _t_apply_ms])

# GPU 上传限流（批量构建队列）

## mesh 组装（同步 GPU 上传）的每帧时间预算与数量上限：常规 3ms / _mesh_build_per_frame；
const _MESH_BUILD_BUDGET_MS := 3.0
const _MESH_BUILD_BUDGET_MS_BURST := 8.0
const _MESH_BUILD_BURST_COUNT := 24

## 每帧从构建队列取一批 chunk 构建 mesh（GPU 上传限流）。
func _process_mesh_build_queue() -> void:
	_mesh_build_scheduled = false
	# DYNAMIC 分组路径：先把待重建的组整份重建（它们不走 _mesh_build_queue）
	if not _group_dirty.is_empty():
		_rebuild_group_meshes(maxi(_mesh_build_per_frame, _MESH_BUILD_BURST_COUNT) / 2 + 1)
	if _mesh_build_queue.is_empty():
		return

	var t0 := Time.get_ticks_usec()
	var built := 0
	# 大量破坏（dirty 多）→ 临时提高本帧构建数/时间预算，减少连续破坏的 mesh 更新延迟感
	var budget_n := _mesh_build_per_frame
	var budget_ms := _MESH_BUILD_BUDGET_MS
	if data and data.get_dirty_mesh_chunk_count() > _mesh_build_per_frame:
		budget_n = maxi(budget_n, _MESH_BUILD_BURST_COUNT)
		budget_ms = _MESH_BUILD_BUDGET_MS_BURST
	# 优先处理已有 mesh 的 chunk（保证破坏面及时更新），再处理新 chunk。
	var pending_keys := _mesh_build_queue.keys()
	var keys: Array = []
	for ck in pending_keys:
		if _lod_meshes[0].has(ck):
			keys.append(ck)
	for ck in pending_keys:
		if not _lod_meshes[0].has(ck):
			keys.append(ck)
	for ck in keys:
		if built >= budget_n:
			break
		var entry: Dictionary = _mesh_build_queue[ck]
		_mesh_build_queue.erase(ck)
		_apply_built_chunk(ck, entry)
		built += 1
		# 自适应：若本帧构建已超预算，提前停止避免帧尖峰（大量破坏时预算放宽）
		if (Time.get_ticks_usec() - t0) / 1000.0 > budget_ms:
			break
	# 剩余留待下帧：由 _process 每帧检测非空后调度（一帧至多一次）。
	if diag_enabled and built > 0:
		print("[诊断] GPU上传批处理: %d chunk, 耗时%.2f ms, 剩余%d" % [
			built, (Time.get_ticks_usec() - t0) / 1000.0, _mesh_build_queue.size()])

## 可见性决策：挂视点层时问它，否则全量放行（"没装视点层 = 不做剔除"）。
func _filter_visible(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if view_layer == null:
		return chunks
	return view_layer.filter_chunks(chunks)

## 卸载半径（视点层未挂时为 0 = 不做距离淘汰）。
func _view_unload_d() -> float:
	return view_layer.unload_d() if view_layer != null else 0.0

## 各 LOD 层外半径（分带表）。
func _view_lod_outer() -> Array[float]:
	return view_layer.lod_outer() if view_layer != null else ([] as Array[float])

## 粗 LOD 大块 mesh 帧尾挂载（deferred 转发目标）。
func _flush_lod_mesh_apply_queue() -> void:
	if view_layer != null:
		view_layer.process_lod_mesh_apply_queue()

## 应用单个待构建 chunk（构建 mesh + 挂载节点 + 更新碰撞）
func _apply_built_chunk(chunk_key: Vector3i, entry: Dictionary) -> void:
	# 带外校验：破坏/编辑不应让超出 LOD0 带的 chunk 临时挂载（否则粗层区破坏时
	if draw_mode == DrawMode.DYNAMIC and visibility_mode != VisibilityMode.FULL:
		var cam := current_camera()
		# 显式标注：内核 ↔ 视点层互持引用（类型环），此处 `:=` 推导会失败。
		var lod_outer: Array[float] = _view_lod_outer()
		if cam and not lod_outer.is_empty():
			var lod0_d: float = lod_outer[0]
			var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
			if _chunk_center_dist(chunk_key, cam.global_position, chunk_size_world, global_position) > lod0_d + chunk_size_world * 0.5:
				collision.remove(chunk_key)
				return
	var arr: Dictionary = entry["arrays"]
	var has_voxels_in_data: bool = entry["has_voxels"]
	# 本帧所有 chunk 共用同一份运行时 Material 对象数组（走唯一材质缓存，不另建）。
	var mats_for_chunk := _materials.surfaces(data.materials) if data else []

	# 【DYNAMIC 分组路径】group_shift > 0 时绘制单元是 **group** 而不是 chunk。
	if draw_mode == DrawMode.DYNAMIC and group_shift > 0:
		if has_voxels_in_data and not arr.is_empty():
			_chunk_arrays[chunk_key] = arr
		else:
			_chunk_arrays.erase(chunk_key)
		_group_dirty[VoxelMesher.group_of(chunk_key, group_shift)] = true
		collision.enqueue(chunk_key, has_voxels_in_data)
		return

	# 获取或创建该 chunk 的子 MeshInstance3D
	var chunk_mesh: MeshInstance3D
	if _lod_meshes[0].has(chunk_key):
		chunk_mesh = _lod_meshes[0][chunk_key]
	else:
		chunk_mesh = MeshInstance3D.new()
		chunk_mesh.name = "Chunk_%d_%d_%d" % [chunk_key.x, chunk_key.y, chunk_key.z]
		add_child(chunk_mesh)
		# 新建的节点默认可见 —— 粒子模式下必须立刻隐藏（异步建网格的竞态，见 _meshes_should_be_visible）
		chunk_mesh.visible = _meshes_should_be_visible()
		_lod_meshes[0][chunk_key] = chunk_mesh

	var has_mesh := false
	if not arr.is_empty() and has_voxels_in_data:
		# 材质随 arrays 一起交给生成器（按**实际 surface 序号**绑）。
		var new_mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr, mats_for_chunk)
		chunk_mesh.mesh = new_mesh
		has_mesh = new_mesh != null
	elif not has_voxels_in_data:
		# chunk 已无体素，清除 mesh 数据并移除容器防止累积
		chunk_mesh.mesh = null
		chunk_mesh.queue_free()
		_lod_meshes[0].erase(chunk_key)
	else:
		# 竞态：生成后体素被重新添加，保留已有 mesh
		has_mesh = chunk_mesh.mesh != null

	if has_voxels_in_data or _lod_meshes[0].has(chunk_key):
		chunk_mesh.position = Vector3(chunk_key) * (voxel_scale * VoxelChunkGenerator.CHUNK_SIZE)
		# 碰撞增量重建交给 VoxelCollision 组件，它自己每帧限量（数量 + 毫秒双限流）
		collision.enqueue(chunk_key, has_mesh)
	else:
		collision.remove(chunk_key)

## DYNAMIC 分组路径：帧尾整组拼装（调用点见 _process_mesh_build_queue）。
func _rebuild_group_meshes(budget_n: int) -> void:
	if _group_dirty.is_empty():
		return
	# 【必须带 data 空判】data 被置空（换模型 / 卸载）到 _clear_lod_meshes 清空 _group_dirty…
	var mats := _materials.surfaces(data.materials) if data else []
	var t0 := Time.get_ticks_usec()
	var built := 0
	for gk in _group_dirty.keys():
		if built >= budget_n:
			break
		_group_dirty.erase(gk)
		var merged := VoxelMesher._new_arrays()
		var any := false
		var group_origin := VoxelMesher.group_origin_chunk(gk, group_shift)
		var chunk_world := voxel_scale * VoxelChunk.CHUNK_SIZE
		for ck in VoxelMesher.chunks_in_group(gk, group_shift):
			var arr: Dictionary = _chunk_arrays.get(ck, {})
			if arr.is_empty():
				continue
			# 顶点是 chunk 局部坐标 → 平移到"相对组原点"，整组共用一个节点位置
			VoxelMesher.append_arrays(merged, arr, Vector3(ck - group_origin) * chunk_world)
			any = true
		var node: MeshInstance3D = _group_meshes.get(gk)
		if not any:
			if node != null and is_instance_valid(node):
				node.queue_free()
			_group_meshes.erase(gk)
			# 整组无几何 → 该绘制单元的碰撞体一并释放（否则留下与画面错位的幽灵碰撞）
			collision.enqueue(VoxelMesher.group_origin_chunk(gk, group_shift), false)
			built += 1
			continue
		var new_mesh := VoxelMesher.to_mesh(merged, mats)
		if new_mesh == null:
			if node != null and is_instance_valid(node):
				node.queue_free()
			_group_meshes.erase(gk)
			collision.enqueue(VoxelMesher.group_origin_chunk(gk, group_shift), false)
			built += 1
			continue
		if node == null or not is_instance_valid(node):
			node = MeshInstance3D.new()
			node.name = "Group_%d_%d_%d" % [gk.x, gk.y, gk.z]
			add_child(node)
			node.visible = _meshes_should_be_visible()
			_group_meshes[gk] = node
		node.mesh = new_mesh
		var edge := voxel_scale * VoxelChunk.CHUNK_SIZE * float(1 << group_shift)
		node.position = Vector3(gk) * edge
		# 组几何变了 → 该绘制单元的碰撞形状重建（组件内部把 chunk 换算成 group 单元）
		collision.enqueue(VoxelMesher.group_origin_chunk(gk, group_shift), true)
		built += 1
		if (Time.get_ticks_usec() - t0) / 1000.0 > _MESH_BUILD_BUDGET_MS_BURST:
			break
	if diag_enabled and built > 0:
		print("[诊断] DYNAMIC 整组拼装: %d 组, 耗时%.2f ms, 剩余%d"
				% [built, (Time.get_ticks_usec() - t0) / 1000.0, _group_dirty.size()])

## 批次完成清理：当所有任务都完成后执行
func _on_batch_complete() -> void:
	# 只读快照已由 VoxelMeshBatch 在结算时释放，此处无需再配对释放。
	if _pending_retrigger:
		_pending_retrigger = false
		if diag_enabled:
			print("[诊断] 触发 Retrigger: 启动新任务")
		_dirty = true
		_update_mesh()
	else:
		# 脏体素追踪已在 _update_mesh_async 启动任务时清除，无需重复清理
		pass

	# 批次完成信号（外部依赖此信号感知场景更新完毕）
	mesh_updated.emit()

## 清理所有 chunk 子 MeshInstance3D 及关联碰撞体
func _clear_lod_meshes() -> void:
	if view_layer != null:
		view_layer.clear_lod_state()
	_mesh_build_queue.clear()
	_materials.invalidate_aligned()
	# 清理所有 LOD 层网格（LOD0 chunk + 各粗层大块；null 表示空大块标记，跳过）
	for level in _lod_meshes.size():
		for bk in _lod_meshes[level]:
			var mi: MeshInstance3D = _lod_meshes[level][bk]
			if mi != null and is_instance_valid(mi):
				mi.queue_free()
		_lod_meshes[level].clear()
	# DYNAMIC 分组绘制单元与待重建集合（与 _lod_meshes 是两套账本，见 _group_meshes 注释）
	for gk in _group_meshes:
		var gn: MeshInstance3D = _group_meshes[gk]
		if gn != null and is_instance_valid(gn):
			gn.queue_free()
	_group_meshes.clear()
	_group_dirty.clear()
	_chunk_arrays.clear()
	if data:
		data.clear_lod_cache()
	if _collision != null:
		_collision.clear_all()
