@tool
class_name VoxelRenderer
extends MeshInstance3D

## 体素专属渲染器
## 持有 QVoxelSource，在运行时动态生成并更新 mesh
## 监听数据变化自动重新生成，支持运行时动态修改体素
## 提供与编辑器导入等价的纹理材质 (基于材质ID的UV采样)

# 【INF】视点相关成员标记约定
#   被 `# [INF]` 标注的成员属于"无限层"（视点相关调度）：① LOD 分带/块调度 ② 流式加载卸载
#   ③ 视锥剔除 ④ 原点漂移 ⑤ 异步块供需。调度逻辑与账本已迁至 VoxelInfiniteLayer，
#   本文件仅剩两类标记：**留节点的 `@export` 配置旋钮**（无限层是 RefCounted，挂不了 @export）
#   与 **1 个 deferred 委托壳**（`_flush_lod_mesh_apply_queue`：deferred 目标须是节点，
#   避免 RefCounted 被释放后野调用）。
#   约定：标记行紧贴成员的 `##` 文档块上方；一个成员的区间 = 标记行起，至下一个顶格非空行止。
# ── 内核对外契约────────────────────────────────────────────────────────
# 【目标形态】内核公开 API 只有两种形状：**按 chunk 索引** 与 **脏区域事件**。
#   "整块重算"式接口（重算全部 chunk / 返回整个世界）一律不提供 —— 那是无限层挂不上来的根因。
#   注意 `request_update()` **不是**"整块重算"：它只置一个"下一帧重建"的唤醒位，真正的重建
#   粒度始终是 chunk，由数据层脏账本（`VoxelDirtyLedger` → `data.get_dirty_chunks()`）给出。
# 【A. 脏区域事件（内核 → 外层，唯一载体）】
#   内核在 `_update_mesh_async` 把脏 chunk 列表交给外层做可见性决策：
#     `infinite_layer.filter_visible_chunks(rebuild_chunks)`（首次全量时传的是全部 chunk 列表）。
#   脏区域真值只有一份：`QVoxelSource` 的 mesh 脏位（`get_dirty_chunks()` / `mark_chunk_dirty()`）。
#   粒度可断言（见 Scripts/Test/test_voxel_kernel_contract.gd）：内部点编辑 → 恰好 1 个 chunk；
#   chunk 角点编辑 → 恰好 4 个（自身 + 3 个负向邻块）；**永不**退化为"全部 chunk"。
# 【B. 按 chunk 索引 · 写】
#   request_update()               唤醒下一帧重建（粒度由脏账本决定）
#   remove_chunk_mesh(ck)          释放该 chunk 的网格（+碰撞+队列条目）
#   shift_render(shift, cs_world)  原点漂移：整体平移渲染账本（一次性，不在每帧路径）
#   mount_lod_mesh / mark_lod_block_empty / clear_lod_mesh    粗层块网格挂 / 标空 / 卸
#   set_lod_level_count / clear_lod_level                     粗层层数
# 【C. 按 chunk 索引 · 查】
#   has_chunk_mesh(ck) / has_lod_mesh(level, bk) / lod_mesh(level, bk) / lod_mesh_keys(level)
#   is_mesh_build_queued(ck) / lod_materials(level) / lod_level_count() / surface_materials()
# 【D. 只读环境】
#   data / voxel_scale / global_position（节点自带） / current_camera() / get_data()
# 【E. 生命周期覆盖点】
#   on_origin_shift(shift)   子类（VoxelDestructible）平移自己的在途队列
# 【F. 兼容别名 / 插件公开 API（P4 收口；勿新增依赖）】
#   mark_dirty（= request_update） / force_update / regenerate_materials
#   set_voxel / remove_voxel / get_voxel
# 【不在契约内】相机、LOD 分带、流式加载卸载、视锥剔除、原点漂移判定、异步块供需
#   —— 全在 VoxelInfiniteLayer。内核只回答"按 chunk 建 / 删网格"。
# 【依赖方向】无限层 → 内核：读上述面 + 按键写网格账本（另按既有约定读 5 个 `@export`
#   私有旋钮 `_stream_*` / `_lod_*`：RefCounted 挂不了 @export，配置有意留在节点上）。
#   内核 → 无限层：只走它的公开方法（`filter_visible_chunks` / `process_*` / `deferred_is_empty`
#   / `is_deferred` / `unload_d` / `lod_outer` / `take_lod_mesh_flush_request` / `abort` /
#   `clear_lod_state` / `on_mesh_removed` / `set_visibility_mode` / `configure_lod`），
#   **不触碰它的私有字段**。
# 【锁定】本清单与 test_voxel_kernel_contract 的期望表一一对应：增删任何公开方法必须同时改两处。

signal mesh_updated

## 无限层（视点调度）：视锥剔除 / 延迟补建队列 / 流式加载与卸载 / 卸载半径 / 原点漂移。
## 【依赖方向】内核只回答"按 chunk 建 / 删网格"，视点决策全部委托给它（详见 VoxelInfiniteLayer）。
## 【为何惰性创建而非 _init 里建】脚本热重载不会对既有节点实例重跑 _init，用 getter 可自愈，
## 避免"重载后旧实例的 infinite_layer 仍为 null"这类只在编辑器里冒出来的空引用。
# ── 粒子渲染（可选）──────────────────────────────────────────────────────────
# 【定位】渲染器负责"把体素显示成粒子"这一层**机制**：把数据导出成点云、上传纹理、
# 维护 GPU 粒子节点、按不透明/透明双通道绘制。
# 【不负责什么】粒子怎么动（漂浮/消散/变形/聚合）**不在这里实现** —— 那是具体项目的
# 表现效果，应由项目自己写粒子着色器或直接操作 particle 节点。
# 本类只保证：给你一个已经填好点云、材质、双通道材质的 GPUParticles3D，
# 并且它的坐标与网格渲染**完全重合**（同一套 center_offset × voxel_scale）。
#
# 用法：
#   $VoxelRenderer.display_mode = VoxelRenderer.DisplayMode.PARTICLES   # 切粒子
#   $VoxelRenderer.particle_node                 # 自己的粒子着色器接上去
#   $VoxelRenderer.display_mode = VoxelRenderer.DisplayMode.MESH       # 切回网格

## 显示方式：网格（合并面片）还是粒子（每个体素一个方块）。
## 【为什么是枚举而不是 bool】三态是常态：网格 / 粒子 / （将来的）体积直渲。
## bool 一加第三种取值就要破坏 API；枚举只加一项，调用方代码不用改。
enum DisplayMode {
	MESH,       ## 合并面片网格（默认，性能最好）
	PARTICLES,  ## 每个体素一个 GPU 粒子方块（可做形变类表现）
}

## 当前显示方式。切换时自动隐藏另一种（同屏两套会互相穿插，且没有意义）。
@export var display_mode: DisplayMode = DisplayMode.MESH:
	set(v):
		display_mode = v
		_apply_display_mode()

## 【兼容别名】等价于 display_mode == PARTICLES。
## 保留是因为早期版本用它，且读起来比枚举比较更短；写入会同步 display_mode。
var particle_mode: bool:
	get:
		return display_mode == DisplayMode.PARTICLES
	set(v):
		display_mode = DisplayMode.PARTICLES if v else DisplayMode.MESH

## 体素的显示形状：方块还是球。**网格与粒子共用这一个开关**。
##
## 【为什么形状该是渲染器的属性，而不是粒子专属】
## 导入路径早就有 cube/sphere 两种形状（导入选项 mesh/shape），但那是**烘焙期**的选择：
## 运行时换形状就得重新导入。而运行时路径（generate_chunk_dense）此前只有方块面 ——
## 于是"导成球的模型在运行时显示成方块"，同一份数据两条路径长得不一样。
## 现在两条路径都支持，且由同一个属性控制：
##   · MESH 模式：chunk 网格按球体重建（原生 generate_spheres_native）
##   · PARTICLES 模式：draw mesh 换成 SphereMesh（不重建粒子节点）
enum VoxelShape {
	CUBE,    ## 体素方块（默认，拼起来严丝合缝）
	SPHERE,  ## 小球（观感柔和，散开后像粒子）
}

## 体素显示形状。网格与粒子都跟着它变。
@export var voxel_shape: VoxelShape = VoxelShape.CUBE:
	set(v):
		voxel_shape = v
		if v == VoxelShape.SPHERE:
			# 球体网格必须按球重建（方块面不能靠换材质变成球）
			_clear_lod_meshes()
			if data:
				for ck in data.get_loaded_chunk_keys():
					data.mark_chunk_dirty(ck)
			request_update()
		else:
			_clear_lod_meshes()
			if data:
				for ck in data.get_loaded_chunk_keys():
					data.mark_chunk_dirty(ck)
			request_update()
		if _particle_view != null and _particle_view.particle_node != null:
			_sync_particle_view_config()
			_particle_view.apply_shape()

## 【兼容别名】等价于 voxel_shape（早期只有粒子侧用，故叫 particle_shape）。
var particle_shape: VoxelShape:
	get:
		return voxel_shape
	set(v):
		voxel_shape = v

## 球半径相对体素边长的比例（两种模式共用）。
@export_range(0.1, 2.0, 0.01) var sphere_scale: float = 1.0:
	set(v):
		sphere_scale = v
		_rebuild_for_shape_change()

## 球的面数分档。0 = 20 面（最省），1 = 80 面，2 = 320 面。网格与粒子共用。
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



## 粒子点数上限。超出按确定性抽样缩减（同输入同输出，回放可复现）。
@export_range(100, 500000, 100) var particle_max_points: int = 200000

## 只渲染表面体素（跳过被完全包住的）。**透明体素永远保留**（玻璃被包住也看得见后面）。
## cars.vox 实测内部体素占 51%；关掉它们粒子数减半、观感更接近网格渲染。
## 散开/漂浮/变形类效果应关掉 —— 那时内部体素散开后是看得见的。
@export var particle_surface_only: bool = true

## 自发光强度倍率，与网格路径的 MATERIAL_EMISSION_ENERGY 同量级（= 20）。
@export_range(0.0, 100.0, 0.5) var particle_emission_energy: float = 20.0

## 粒子（体素方块）的显示尺寸倍率：1.0 = 与体素等比，拼起来严丝合缝。
@export_range(0.05, 3.0, 0.01) var particle_scale: float = 1.0

## 粒子整体透明度（出场/退场淡出用）。
@export_range(0.0, 1.0, 0.01) var particle_alpha: float = 1.0

## 实际的 GPU 粒子节点。为空表示尚未创建。
## 【交给项目使用】想自定义运动（漂浮/散开/聚合）时，直接给它换 process_material，
## 或读本类的 particle_points 自己上传纹理 —— 本类不做任何"动起来"的事。

## 最近一次导出的点数据（PackedFloat32Array，布局见 QVoxelSource.build_particle_points）。
## 项目若要自己做形态变换，可直接拿它算配对/偏移，不必再问数据层要一遍。


var infinite_layer: VoxelInfiniteLayer:
	get:
		if _infinite_layer == null:
			_infinite_layer = VoxelInfiniteLayer.new(self)
		return _infinite_layer

var _infinite_layer: VoxelInfiniteLayer

## 视点分页层组件（`VoxelInfiniteLayer` 的继任者）。
##
## 【怎么启用】把它作为本节点的子节点挂上，`enabled = true` 即可。挂上之后：
##   · `_process` 只调**本组件**的调度，不再调 `infinite_layer`（两者绝不并行，会互抢账本）；
##   · 脏列表过滤走本组件的 `filter_chunks`，不再走旧层 `filter_visible_chunks`；
##   · LOD 粗层的派发 / 挂载 / 清理全归本组件。
## 没挂（= null）时一切照旧走旧层，所以这是一个**可空、可热插拔**的接管点。
##
## 【为什么是"可空引用"而不是"必须"】并存期要能让两条路径都跑起来做对照验证；
## 而且 @export 挂 Node 引用比在代码里硬 new 更容易让用户理解"这是可选组件"。
## 【这是本类唯一的反向调用】旧层当初就是从这里开始双向耦合的（renderer ↔ 视点层互相调）。
## 为了不再重演，契约压到最小：本类只问"这些 chunk 可见吗"（`filter_chunks`），
## 以及转发"该你了"（`process_*`）。组件侧只读本类公开面，绝不碰 `_` 前缀成员。
var paged_layer: VoxelPagedLayer = null


## 是否已由 `paged_layer` 接管视点调度。所有"该调谁"的分叉都读这一个判据，
## 避免十处各写一遍 `paged_layer != null` 而漏掉某一处（那种漏法表现为"某个子能力不工作"，
## 极难定位）。
func uses_paged_layer() -> bool:
	return paged_layer != null and paged_layer.enabled

# [INF] 视点相关
## 网格生成模式
## 可见性管理模式（决定哪些 chunk 生成网格）
enum VisibilityMode {
	FULL,      ## 全量生成所有 chunk（简单，适合中小世界，内存随世界线性增长）
	FRUSTUM,   ## 视锥剔除：仅生成视锥内（或 view_distance 内）的 chunk，进视锥再补建
	STREAMING, ## 流式加载：按距离生成 + 卸载，远距 chunk 网格释放（适合超大型世界）
}

## 绘制模式：决定"体素几何怎么变成绘制单元"。**这是本类最重要的一个旋钮**。
##
## 【为什么需要它】两条路径的几何内核是同一个，但"组织方式"决定了 draw call：
##   · STATIC  ：全部 chunk 合并成 1 个 ArrayMesh（≤2 surface）挂在**本节点自己**的 mesh 上。
##               N 个实例共享同一份资源 → Godot 自动合批。实测 deer×1000 从 10.67ms 降到 2.15ms，
##               与导入 ArrayMesh 完全持平（导入 2.31ms）。
##   · DYNAMIC ：每 group_shift³ 个 chunk 一个 MeshInstance3D。单次编辑只重建受影响的 group，
##               另有 per-chunk 的异步生成 / 分批上传 / 碰撞 / 流式 / LOD 全套能力。
##
## 【取舍 — 必须让用户知道】STATIC 下改一个体素要重建**整份**模型：
##   deer 1.6~3.1ms / cars 7.4~9.3ms / teapot1 85ms（实测）。
##   所以"静态大模型本来就不该频繁编辑"——要编辑就切 DYNAMIC。这是刻意的设计取舍，
##   与 godot_voxel 对 mesh_block_size 的处理同理（"perfomance tradeoff"）。
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

## 绘制模式。切换时清掉旧模式的全部绘制单元并按新模式重建。
@export var draw_mode: DrawMode = DrawMode.STATIC:
	set(v):
		if draw_mode == v:
			return
		draw_mode = v
		_clear_lod_meshes()
		mesh = null
		request_update()

## DYNAMIC 模式的分组粒度（= 每组 2^group_shift 个 chunk 的边长）。
##
## 【默认 0 = 每 chunk 一个绘制单元，与重构前**字节等价**】这是回归安全的第一原则：
## DYNAMIC 是"可编辑/可破坏/流式"路径，它的默认行为必须和改造前完全一致，
## 否则所有存量场景（destruction_demo / water_sim / 各测试）都会在没人要求的情况下改变行为。
##
## 【那 1/2 什么时候用】分组能大幅减少 draw call（实测 teapot1：158 → 35 → 8），
## 但它是**显式 opt-in**，且只在两种情况划算：
##   ① 多实例共享同一模型（draw 收益乘以实例数）；
##   ② 模型 chunk 密集（≥32 chunk）且编辑不频繁。
## 单实例 + 逐帧编辑（水模拟）应该留在 0：单次重建要尽可能小。
##
## 【为什么默认不是 1】第一版把默认设成 1，结果 destruction_demo（196 chunk / 32 组）
## 模型长期显示不全、water_sim 随机事件掉帧 —— 分组路径的整组重建在**主线程**，
## 每帧预算只有 8ms，组多时追不上连续破坏产生的脏组。详见 docs/重构实施记录.md §5.6。
@export_range(0, 2, 1) var group_shift: int = 0:
	set(v):
		group_shift = clampi(v, 0, 2)
		_clear_lod_meshes()
		request_update()

## DYNAMIC 模式的分组账本：group_key → MeshInstance3D。
## 【为什么单独一张表】`_lod_meshes[0]` 的键是 **chunk 坐标**（LOD 账本、流式、碰撞、测试都按它查），
## 而 DYNAMIC 的绘制单元是 **group 坐标**。两者混在一张表里会让"按 chunk 查是否有网格"失效，
## 破坏内核契约测试（`has_chunk_mesh` / `remove_chunk_mesh` 全部按 chunk 键）。
## 故分组绘制单元独立成表；chunk → group 的映射是纯移位（`VoxelMesher.group_of`）。
var _group_meshes: Dictionary = {}
## DYNAMIC 分组路径的待重建组集合（group_key → true）。帧尾由 _rebuild_group_meshes 消费。
var _group_dirty: Dictionary = {}
## 【分组模式的核心缓存】chunk_key → 该 chunk 的几何数组（worker 在子线程产出）。
##
## 【为什么必须缓存】worker 已经按 34³ 光环（含邻居）生成了每 chunk 的正确几何 ——
## 边界面的可见性已经判好了。旧的实现把这个结果丢掉、帧尾在主线程用 build_group
## 从体素**重新生成**整组，导致：
##   ① 几何算两遍（CPU 翻倍）；
##   ② 第二遍在主线程 → 每帧只有 8ms 预算，组多时几十帧都建不完（destruction_demo
##      196 chunk / 32 组，且 continuous_interval=3 持续破坏 → 脏组永远追不上 → 模型显示不全）。
## 现在改为：这里只缓存 worker 的产出，整组重建退化成**纯拼接**（顶点平移 + 索引偏移），
## 不再有任何几何生成。
var _chunk_arrays: Dictionary = {}

## 体素缩放比例 (单个体素的边长，世界单位)
@export var voxel_scale: float = 0.1:
	set(v):
		voxel_scale = v
		# Voxel scale 变化会影响 chunk mesh 的位置，需要重建。
		# 守卫：本 setter 可能在 _ready()/_configure_lod() 之前被调用（场景反序列化、
		# 编辑器 Inspector 赋值、在 add_child 之前设属性），此时 _lod_meshes 仍为空数组，
		# 直接取 [0] 会越界报错。空数组时无网格可清理，跳过即可。
		if not _lod_meshes.is_empty() and not _lod_meshes[0].is_empty():
			_clear_lod_meshes()
		request_update()
		if display_mode == DisplayMode.PARTICLES:
			rebuild_particles()

## 数据变化时是否自动重新生成 mesh
@export var auto_update: bool = true

## 重建限流帧数：一帧内多次数据变化会被合并，最多每 N 帧重建一次 mesh
## 对大型动态场景(如水模拟)可显著降低重建频率，值越大越流畅但更新越滞后
@export_range(1, 30) var update_throttle_frames: int = 1

# [INF] 视点相关
## 可见性管理模式（统一视锥剔除与流式加载）
## - FULL     ：全量生成所有 chunk（中小世界）
## - FRUSTUM  ：视锥剔除，仅生成视锥内/附近 chunk（大型世界，省生成与显存）
## - STREAMING：流式加载，按距离生成 + 卸载远距网格（超大型世界，显存友好）
## 注：渲染层 GPU 剔除由引擎自动完成，此选项控制 CPU 侧生成调度
@export var visibility_mode: VisibilityMode = VisibilityMode.FRUSTUM:
	set(v):
		visibility_mode = v
		# 同步流式启用状态：运行时切换 STREAMING 立即生效（原只在 _ready 设置一次，
		# demo 在 _ready 之后才设 STREAMING 会导致流式从不启用）。
		# 视点层一并清空延迟队列（FULL 下补建队列失去意义）。
		infinite_layer.set_visibility_mode(v)
		if paged_layer != null:
			paged_layer.on_visibility_mode_changed(v)
		if v == VisibilityMode.FULL:
			# 全量模式下补建已加载 chunk 的网格（卸载的由统一流式按需重载）
			if data:
				for ck in data.get_loaded_chunk_keys():
					data.mark_chunk_dirty(ck)
		request_update()
		# 可见性变化影响多个属性的有效性 → 刷新 Inspector（隐藏/显示条件属性）
		notify_property_list_changed()


# [INF] 视点相关
## Inspector 动态可见性：条件不生效时隐藏对应属性（避免用户设置后无效）。
## Godot 4 在 Inspector 刷新时对每个属性调用此方法，可修改 usage 隐藏。
func _validate_property(property: Dictionary) -> void:
	var name: StringName = property["name"]
	var hide := false
	match name:
		&"view_distance", &"unload_distance", &"lod_count":
			# FULL 全量模式不走流式/LOD，距离参数无效
			hide = visibility_mode == VisibilityMode.FULL
		&"_stream_unload_per_frame", &"_stream_load_per_frame":
			# 流式加载/卸载限速仅 STREAMING 生效
			hide = visibility_mode != VisibilityMode.STREAMING
		&"_lod_build_per_frame", &"_lod_build_budget_ms":
			# LOD1 生成参数仅启用 LOD（lod_count > 1）时生效
			hide = lod_count <= 1
		&"_collision_rebuild_per_frame":
			# 碰撞重建限速仅开启碰撞（generate_collision）时生效
			hide = not generate_collision
	if hide:
		property["usage"] = int(property["usage"]) & ~PROPERTY_USAGE_EDITOR

# [INF] 视点相关
## 可见性加载距离（世界单位）：FRUSTUM 时视锥外仍生成的半径；STREAMING 时网格加载半径
@export var view_distance: float = 40.0:
	set(v):
		view_distance = v
		infinite_layer.configure_lod(lod_count, view_distance)
		if paged_layer != null:
			paged_layer.view_distance = v

# [INF] 视点相关
## 流式卸载距离（世界单位，仅 STREAMING）：超过此距离的 chunk 网格被卸载释放
## 默认 0 = 自动取 view_distance * 1.2
@export var unload_distance: float = 0.0

# [INF] 视点相关
## LOD 层级数（含 LOD0）：1=仅全精度（默认，等价旧版 lod0_distance=0 关闭 LOD）；
## 2=LOD0+LOD1(2×)；3=+LOD2(4×)；4=+LOD3(8×)…
## 各层自动按 view_distance 等比（×2）分带：LOD_i 外半径 = view_distance / 2^(lod_count-1-i)。
@export_range(1, 8, 1) var lod_count: int = 1:
	set(v):
		lod_count = clampi(v, 1, 8)
		_configure_lod()
		notify_property_list_changed()

# [INF] 视点相关
## 可见性检查间隔（帧）：视锥/流式统一每隔 N 帧检查一次相机位置。
## 值越大 CPU 开销越低，但进入视锥/加载距离后的补建响应越慢。
@export_range(1, 120) var visibility_check_interval: int = 8

# ── LOD 网格账本（渲染层）────────────────────────────────────────────────────
## 各 LOD 层渲染网格：_lod_meshes[lod] = {block_key: MeshInstance3D}。
## index 直接 = LOD 层级：0 = 全精度 chunk（level 0 block key == chunk key），>=1 = 粗层大块。
## 值为 null = "空标记"（该大块确定无体素，无限层据此停止重复派发）。
## 【为什么这套账本留在内核】见 VoxelInfiniteLayer 类注释"为什么网格账本留在内核"：
## remove_chunk_mesh / has_chunk_mesh / shift_render 都要读它，
## demo 与测试的 HUD 也直接读它统计 chunk 数；搬进无限层即构成反向依赖。
var _lod_meshes: Array[Dictionary] = []

# LOD 大块（godot_voxel 风格大 block）：GRID³ 大格，每格 = 2^level 体素。
#   level 0 = chunk（GRID = CHUNK_SIZE = 32，block key == chunk key）
#   level i = 大块覆盖 (32×2^i)³ 体素，block key = chunk key >> i
# 一次生成整个大块 mesh（原生 32³ 网格核心 generate_chunk_dense / generate_lod1_block_dense）。
# 几何数学（block 划分 / 层边长 / 中心距 / 滞回 / 预生成 / 分带）的唯一实现在 VoxelLodGrid；
# 分带调度（枚举 / 供需 / 可见性兜底）在无限层，本类只留节点挂载需要的层边长。
const LOD_GRID := VoxelLodGrid.GRID


## 见 VoxelLodGrid.block_edge_world（本类挂载节点与 origin shift 需要层边长）
func _lod_block_edge_world(level: int) -> float:
	return VoxelLodGrid.block_edge_world(level, voxel_scale)


# ── LOD 调度旋钮（配置留节点，逻辑归无限层）──────────────────────────────────
# 【为什么这些 @export 不随调度搬进无限层】`@export` 只能挂 Node / Resource，无限层是
# RefCounted（不进场景树、不序列化）。搬过去 = 用户从此在 Inspector 里看不到、也存不进场景，
# 对一个插件是把"可调"变成"要改代码"。故只搬状态与逻辑，配置留在节点由无限层读取。
## 每帧最多派发/挂载的粗 LOD 网格数（硬上限；mesh 由工作线程构建，挂载仅赋值，可适当调大）
@export_range(1, 400, 1) var _lod_build_per_frame: int = 128

## 粗层预生成提前量（block 数）：把粗层 block 的生成范围向外扩展，
## 让它们在进入 LOD 带之前就生成好——相机跨带时新层级已就绪，
## 消除"旧层已移除、新层异步生成中"的真空窗口（移动中闪现空洞）。
## 0 = 关闭（只在进入带后才生成）；建议 1~3（越大越无感，预加载 ring 常驻量略增）。
@export_range(0, 6, 1) var _lod_preload_blocks: int = 1

## LOD1 生成每帧时间预算（毫秒）：超过即停止本帧生成，平滑移动时主线程峰值
@export_range(0.1, 50.0, 0.1) var _lod_build_budget_ms: float = 8.0

# 共享的后台数据生成提交预算：数量硬上限 _lod_submit_per_frame（防单帧洪峰打爆 WorkerThreadPool）。
# 数量足够大 → 近层提交完自然让位更远层（不饿死，各 LOD 层都能提交）。
@export_range(1, 500, 1) var _lod_submit_per_frame: int = 200


## 重新计算 LOD 分带并调整各层存储（lod_count/view_distance 变化时调用）。
## LOD_i 外半径 = view_distance / 2^(lod_count-1-i)（等比 ×2，对齐 Voxel Tools 标准做法）。
func _configure_lod() -> void:
	# 分带计算 + 各层容器长度对齐都归视点层：它持 4 张调度表、本类持网格账本 `_lod_meshes`，
	# 长度由它唯一驱动（见 VoxelInfiniteLayer.configure_lod / VoxelPagedLayer._ensure_bands），
	# 避免两边各自 resize 后悄悄错位。
	infinite_layer.configure_lod(lod_count, view_distance)
	if paged_layer != null:
		# 接管后本类不再替它维护层数：push 进去，由它在下一轮 _ensure_bands 里自行对齐
		# 自己的 4 张表和本类的 _lod_meshes（单点维护，避免两处各算一遍）。
		paged_layer.lod_count = maxi(lod_count, 1)
	if data:
		data.lod_count = lod_count
		if lod_count <= 1:
			data.clear_lod_cache()
	request_update()


## 对齐本类网格账本 `_lod_meshes` 的层数（由无限层的 configure_lod 驱动）。
## 缩减时先释放被裁层的网格节点；扩充时补空的层容器。
func set_lod_level_count(n: int) -> void:
	while _lod_meshes.size() > n:
		clear_lod_level(_lod_meshes.size() - 1)
		_lod_meshes.pop_back()
	while _lod_meshes.size() < n:
		_lod_meshes.append({})
	# 材质对齐数组随层数同步（唯一缓存在 _materials 内，不再逐层单独维护）
	_materials.set_level_count(n)


## 释放指定 LOD 层级的全部网格节点（粗层的调度账本归无限层，由它自己 pop 掉）
func clear_lod_level(level: int) -> void:
	if level < 0 or level >= _lod_meshes.size():
		return
	for bk in _lod_meshes[level]:
		var mi = _lod_meshes[level][bk]
		if mi != null and is_instance_valid(mi):
			mi.queue_free()
	_lod_meshes[level].clear()

## 是否生成静态碰撞体 (StaticBody3D + ConcavePolygonShape3D)
## 【实现已下沉到 VoxelCollision 组件】本类只保留这个开关与两个限流旋钮，
## 真正的建/删/复用与每帧限量都在组件里。关掉时组件清空自己的账本，不会残留碰撞体。
@export var generate_collision: bool = false:
	set(v):
		generate_collision = v
		collision.enabled = v
		if not v:
			collision.clear_all()
		request_update()
		notify_property_list_changed()

## 碰撞组件（懒创建的子节点）。
## 【为什么懒创建】与 infinite_layer 同因：脚本热重载不会对既有实例重跑 _init，
## 用 getter 可自愈；而且不开碰撞时不必凭空多一个节点。
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
## 关闭（默认）时仅在单次重建超时阈值（如单 chunk 生成 >5ms）时才打印，避免刷屏
@export var diag_enabled: bool = false

var _dirty: bool = false
## 材质唯一缓存：快照 / 运行时材质 / 各层对齐数组三份派生都在它内部，失效只有 invalidate() 一个入口
var _materials := VoxelMaterialCache.new()
var _update_counter: int = 0

# 流式卸载每帧限量：相机移动跨越边界时分批进行，避免一次 queue_free 大量节点
# 造成掉帧。卸载只释放资源+写盘（便宜），限量可稍大。
# [INF] 视点相关
@export_range(1, 200, 1) var _stream_unload_per_frame: int = 24
# 流式加载每帧限量：走近时优先补建最近的 chunk（磁盘读回 + 入异步重建）。
# 加载标脏后由 WorkerThreadPool 异步生成 + _process_mesh_build_queue 帧尾限量构建
# （GPU 上传限流 8 个/帧 + 3ms 预算），因此标脏量可适当放大：走近时每帧进入
# 管线的新块多，但实际 mesh 出现仍由 GPU 限流平滑分摊，不会掉帧也不会"一帧一块"。
# [INF] 视点相关
@export_range(1, 200, 1) var _stream_load_per_frame: int = 32
# 统一流式异步请求的在途状态不再本地留存：账本唯一在 VoxelAsyncLoader。
# 查询走 QVoxelSource.is_chunk_pending() / 列举 get_unready_chunk_keys() / 取消 cancel_chunk_request()。
# 当前渲染扇出批次：同时持有"任务计数"与"只读快照句柄"，结算点唯一（见 VoxelMeshBatch）。
# 任务计数与快照不再各自散落维护——旧实现里结果处理的两条早退路径各减一次计数，
# 导致计数提前归零、快照在 worker 仍在读时被释放，COW 写保护被击穿。
var _batch: VoxelMeshBatch = null
var _exiting := false                    # 退出中：worker 结果回调据此直接丢弃，避免访问已清理数据
# 异步任务运行期间收到新变更时置位，任务完成后重新触发更新（保证数据始终最新且不并发）
var _pending_retrigger: bool = false
# 批次全部完成待处理标志：置位后下一帧 _process 执行 _on_batch_complete（避免主线程尖峰）
var _batch_complete_pending: bool = false
# Per-chunk 模式：每个非空 chunk 对应一个子 MeshInstance3D（LOD0 网格存于 _lod_meshes[0]）
# 碰撞账本已下沉到 VoxelCollision 组件（见 collision getter），本类不再持有碰撞体。
# 保留这两个旋钮：它们是 Inspector 上暴露给用户的限流配置，透传给组件。
# 每帧最多重建的碰撞体数
@export_range(1, 100, 1) var _collision_rebuild_per_frame: int = 12:
	set(v):
		_collision_rebuild_per_frame = v
		if _collision != null:
			_collision.rebuild_per_frame = v
## 每帧碰撞重建的时间预算（毫秒）。单个 chunk 的 ConcavePolygonShape3D 约 10~15ms，
## 只按块数限流仍会一帧堆 12 块 → 百毫秒级尖峰。预算到点就停，宁可分几帧建完。
## 0 = 只受 _collision_rebuild_per_frame 限制。
@export_range(0.0, 100.0, 0.5) var collision_rebuild_budget_ms: float = 4.0:
	set(v):
		collision_rebuild_budget_ms = v
		if _collision != null:
			_collision.rebuild_budget_ms = v

# GPU 上传限流队列：异步结果先缓存数组数据，_process 帧尾批量构建 mesh（平滑 GPU 上传，
# 避免连续破坏时一帧大量 ArrayMesh 创建导致 Metal fence 超时）
# key: chunk_key -> {arrays: Dictionary, has_voxels: bool}
var _mesh_build_queue: Dictionary = {}
# 每帧最多构建的 chunk 数（GPU 上传限流）
# 流式补建直接入此队列，单 chunk 构建成本低（~1ms），提高后补建更流畅；
# 配合 3ms 时间预算 + GPU 忙检测兜底防 Metal fence 超时
@export_range(1, 100, 1) var _mesh_build_per_frame: int = 12
# 增量重建每帧最多处理的 dirty chunk 数：超出放回下帧续建（防回原点/大崩塌单帧
# 快照+派发上千 worker 阻塞主线程）。值越大重建越快但帧尖峰风险越高。
# 默认按 CHUNK_VOLUME 等比缩放：64 是 16³（4096 体素）时代调的值；32³ 单个 halo
# 快照约 2~4ms，64 个/帧 ≈ 主线程 130~200ms → 等比换算 16³的64 ≈ 32³的8。
# 数量之外另有毫秒预算双保险（_snapshot_budgeted）。
@export_range(8, 512, 8) var _rebuild_batch_limit: int = 64 * 4096 / VoxelChunk.CHUNK_VOLUME

# 帧尾构建是否已排期（防重复 call_deferred）
var _mesh_build_scheduled: bool = false
# 上一帧 _delta（秒），GPU 忙检测用（帧耗时大 = GPU/渲染压力高）
var _last_frame_delta: float = 0.0

## 最近一次网格生成耗时（毫秒），供外部 HUD 等调试显示
var last_mesh_gen_time_ms: float = 0.0

## 性能追踪：上次生成的顶点数/三角形数
var last_solid_vertices: int = 0
var last_trans_vertices: int = 0
var last_solid_triangles: int = 0
var last_trans_triangles: int = 0
var last_total_chunks: int = 0

## 性能追踪：最近一次重建的 chunk 数量与耗时明细
var last_rebuild_chunk_count: int = 0      ## 本次重建的 chunk 数
var last_rebuild_affected_count: int = 0   ## 受影响的 chunk 数（含相邻边界）
var last_mesh_gen_time_slice_ms: float = 0.0  ## 生成阶段耗时（不含 apply）
var last_apply_time_ms: float = 0.0        ## 应用到场景的耗时 (ms)

## 累计性能统计（简化版 - 仅保留必要统计，避免数组操作开销）
var perf_stats: Dictionary = {
	"total_gen_time": 0.0,    # 累计生成耗时
	"total_apply_time": 0.0,  # 累计应用耗时
	"sample_count": 0,        # 采样次数
}

## 记录一次性能统计采样（轻量级，仅累加数值，不维护数组）。
## apply_time_ms 由调用方传入**实测值**；此前这里被以 `last_apply_time_ms` 自身为实参调用，
## 于是该字段永远是"把自己的旧值赋给自己"（恒为 0），而 demo 会读它做展示。
func _record_perf_stats(chunk_count: int, gen_time_ms: float, apply_time_ms: float) -> void:
	last_rebuild_chunk_count = chunk_count
	last_mesh_gen_time_slice_ms = gen_time_ms
	last_apply_time_ms = apply_time_ms
	
	var stats := perf_stats
	stats["total_gen_time"] = stats["total_gen_time"] as float + gen_time_ms
	stats["total_apply_time"] = stats["total_apply_time"] as float + apply_time_ms
	stats["sample_count"] = stats["sample_count"] as int + 1


func _ready() -> void:
	_configure_lod()
	request_update()
	# GPU 忙检测统一用帧时长（_last_frame_delta）：viewport_set_measure_render_time
	# 在部分驱动(如 Metal)上可能引发不稳定，故不启用引擎侧的 render time 测量。
	# 流式加载启用判定：visibility_mode == STREAMING 即启用（unload 默认见 infinite_layer.unload_d()）
	infinite_layer.set_visibility_mode(visibility_mode)


func _process(_delta: float) -> void:
	# 记录上一帧耗时，供 GPU 忙检测使用（_process_mesh_build_queue）
	_last_frame_delta = _delta

	# 【STATIC = 真的最简：整段视点调度直接跳过】
	# STATIC 下几何是"整份重建一次挂在自己身上"，没有任何 chunk 级调度、没有流式、
	# 没有 LOD 分带。此前这里无差别跑 process_lod / process_streaming，结果是
	# STATIC 的实例每帧仍付一遍视点扫描（实测 deer×1000 多花 1.1ms/帧），而它们根本用不到。
	# 这是"最简路径必须真的最简"这条规则在代码里的落点。
	if draw_mode == DrawMode.STATIC:
		_drive_static()
		return
	_process_dynamic_body()


## STATIC 模式的每帧驱动：只有"脏了才重建"，别的什么都不做。
##
## 【为什么单独一条路径而不是 if 包一层】STATIC 的价值就是"零调度开销"：
## 挂 1000 个实例时，任何每帧的视点扫描都会乘上实例数。这里刻意只保留
## `_dirty` → `_update_mesh()`（内部再走共享 mesh 缓存，第 2 个实例起是 O(1) 取指针）。
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
	# 【谁驱动：paged_layer 挂了就只调它，否则走旧层】两者绝不并行——它们操作的是同一批
	# 网格账本（_lod_meshes / 数据脏账），同时跑会互相把对方刚建的网格判成"该移除"，
	# 表现为持续闪烁与 worker 空转。所以这里是**互斥分叉**，不是"两个都跑"。
	var via_paged := uses_paged_layer()
	if via_paged:
		paged_layer.process_streaming()
		paged_layer.process_deferred_chunks()
		paged_layer.process_lod()
	else:
		if visibility_mode != VisibilityMode.FULL:
			infinite_layer.process_deferred_chunks()
		# 统一流式/程序化驱动：程序化无限世界总是按距离生成（不依赖 visibility_mode——
		# 无限世界只能按距离生成，设 FULL/FRUSTUM 若不走流式会导致数据永不生成 → 画面空白）；
		# 磁盘文件流仅在 STREAMING 模式启用加载/卸载。
		if infinite_layer.streaming_enabled or (data and data.is_streaming()):
			infinite_layer.process_streaming()
		# LOD 管理：每 interval 帧限量生成/移除（降低每帧遍历开销，近处 LOD0 / 远处各粗层互补）。
		# 降频与"数据变化立即处理"的判定都在视点层内部（它持有 _cull_check_counter）。
		infinite_layer.process_lod()

	# GPU 上传限流：帧尾批量构建队列中的 chunk mesh（避免与渲染/崩塌竞争 GPU）
	# call_deferred 确保在帧末尾执行（本帧渲染已提交），且队列处理不阻塞主循环
	# 【DYNAMIC 分组模式】绘制单元是 group 而不是 chunk，结果全部进 _group_dirty；
	# 这里必须一并排期，否则整组重建永远不会发生（曾经的 bug：只有 _mesh_build_queue 判空）。
	if (not _mesh_build_queue.is_empty() or not _group_dirty.is_empty()) and not _mesh_build_scheduled:
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")
	# 粗 LOD 大块 mesh 挂载同样帧尾限量（大块 mesh 覆盖数十万体素，GPU 上传昂贵）。
	# 队列与排期标记都归视点层，本类只负责把 deferred 挂在自己身上（节点被释放时引擎会
	# 自动丢弃排期，而 RefCounted 的旧层不享受这层保护——这是本类仍持有这个壳的唯一原因）。
	var lod_flush := paged_layer.take_lod_mesh_flush_request() if via_paged \
			else infinite_layer.take_lod_mesh_flush_request()
	if lod_flush:
		call_deferred("_flush_lod_mesh_apply_queue")

	# 碰撞增量重建已下沉到 VoxelCollision 组件（它有自己的 _process 与双限流），
	# 本类不再调度它 —— 只在网格应用完成后调 collision.enqueue(ck, has_mesh)。

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
	# 若此时覆盖 _batch，上一批的结果会因"批次身份不符"被丢弃，这些 chunk 的重建
	# 将永久丢失 → 界面残留被破坏面的"幽灵面"。
	# 改为置位 retrigger，等当前批次完成后在 _on_batch_complete 中重新触发，
	# 保证每个脏 chunk 最终都得到一次应用。
	if _batch != null and _batch.is_active():
		_pending_retrigger = true
		return

	_update_mesh()


# ── 粒子渲染：公开接口（实现已下沉到 VoxelParticleView 组件）──────────────
#
# 【契约保持不变】`display_mode` / `voxel_shape` / `particle_*` 旋钮与
# `particle_node` / `particle_points` / `show_as_particles()` / `rebuild_particles()` /
# `particle_voxel_size()` 全部仍是本类的公开面 —— 存量调用方（particle_demo 等）零改动。
# 真正的点云导出 / 纹理上传 / 粒子节点生命周期在 `VoxelParticleView` 里。

## 粒子视图组件（懒创建的子节点）。
## 【为什么懒创建】与 infinite_layer / collision 同因：脚本热重载不重跑 _init，
## getter 可自愈；且不用粒子时不必凭空多一个节点。
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


## 【兼容别名】等价于 display_mode = PARTICLES / MESH。
func show_as_particles(on: bool = true) -> void:
	display_mode = DisplayMode.PARTICLES if on else DisplayMode.MESH


## 重新导出点云并重建 GPU 资源（转发给组件）。
## 【何时调用】数据改了、voxel_scale 改了、粒子参数改了 —— 任何影响点云内容的变化。
## 纯"运动"变化（进度、漂浮幅度）不需要，那是项目自己的着色器 uniform 的事。
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
## 【为什么需要这个函数，而不是只在切换时遍历一遍】
## 网格是**异步分批**建出来的：切到粒子模式的那一刻账本可能还是空的，
## 之后建出的 Chunk_*/Group_* 节点默认 visible=true —— 于是粒子与网格同时存在。
## 方块形状下两者重合、被粒子挡着看不出来；换成球形就露馅（球之间有缝，能看见底下的网格）。
## 故**创建处**也必须按当前模式设可见性。
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
	# STATIC 下所有挂在同一份 data 上的实例会同时收到本信号。共享 mesh 只该失效一次：
	# 第一个察觉的实例清缓存，其余随后 acquire 时重建一次、之后共享（重建不会发生 N 次）。
	if draw_mode == DrawMode.STATIC:
		VoxelMesher.invalidate_shared_mesh(data)
	request_update()
	# 粒子模式下数据变了要重导点云（网格那套脏账本对点云不适用：
	# 点云没有 chunk 级增量，整份重导 66ms / 2 万点，比维护一套增量账本简单可靠）
	if display_mode == DisplayMode.PARTICLES:
		rebuild_particles()


func request_update() -> void:
	_dirty = true


## 标记为脏，下一帧自动更新 (若 auto_update=true)
func mark_dirty() -> void:
	request_update()


## 立即强制重新生成 mesh
## 若仍有异步任务在运行，不直接启动新批次（否则 _update_mesh_async 会在 worker
## 读取共享切片时再次修改切片缓存 → 数据竞态），而是置位 retrigger，等当前批次
## 完成后由 _on_batch_complete 自动触发重建，保证共享切片引用安全。
func force_update() -> void:
	_dirty = true
	if _batch != null and _batch.is_active():
		_pending_retrigger = true
		return
	_dirty = false
	_update_mesh()


## 强制重新生成纹理材质 (材质属性变化时调用)
func regenerate_materials() -> void:
	# 三份派生一起作废。粗层用的是"按 ID 对齐后的材质快照"，漏作废它的话，已失效重建的
	# 粗层 block 会先用旧对齐材质建网格（新材质只在后续 to_build 路径才刷新）→ 颜色不更新。
	_materials.invalidate()
	request_update()


## 获取当前体素数据
func get_data() -> QVoxelSource:
	return data


## 当前渲染相机（未入树 / 无相机时为 null）。统一入口，替代各处重复的 is_inside_tree 判定。
func current_camera() -> Camera3D:
	return get_viewport().get_camera_3d() if is_inside_tree() else null


## chunk 是否已有渲染网格（"我的体素已经画出来了"）。
##
## 【三种模式的判据不同，这里是唯一入口】
##   · STATIC  ：整份 mesh 一次性建好，任何 chunk 都算"已画"（只要 mesh 存在）
##   · DYNAMIC + group_shift=0：绘制单元就是 chunk，查 _lod_meshes[0]
##   · DYNAMIC + group_shift>0：绘制单元是 group，chunk 的可见网格在它所属的 group 里
## 调用方（碰撞 / 流式 / 测试）不该自己按模式分支 —— 那是本类内部的组织细节。
func has_chunk_mesh(ck: Vector3i) -> bool:
	if draw_mode == DrawMode.STATIC:
		return mesh != null
	if group_shift > 0:
		var gn: MeshInstance3D = _group_meshes.get(VoxelMesher.group_of(ck, group_shift))
		return gn != null and is_instance_valid(gn) and gn.mesh != null
	return not _lod_meshes.is_empty() and _lod_meshes[0].has(ck)


## 该 chunk 的渲染网格节点（碰撞 / 组件按 chunk 定位网格时用）。无网格返回 null。
## 三种模式都归一到这里，避免每个调用方各写一遍 match。
func chunk_mesh(ck: Vector3i) -> MeshInstance3D:
	if draw_mode == DrawMode.STATIC:
		return self if mesh != null else null
	if group_shift > 0:
		var gn: MeshInstance3D = _group_meshes.get(VoxelMesher.group_of(ck, group_shift))
		return gn if gn != null and is_instance_valid(gn) else null
	return _lod_meshes[0].get(ck) if not _lod_meshes.is_empty() else null


## LOD 层数（含 LOD0），= 网格账本 `_lod_meshes` 的长度。
## 长度由无限层 configure_lod 驱动（它持 4 张调度表，长度唯一维护点在那里）。
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
## 不在此恢复，之后所有 worker 结果都会被 _on_batch_result 静默丢弃 —— 渲染器会永久空着。
func _enter_tree() -> void:
	_exiting = false
	if data != null:
		request_update()


func _exit_tree() -> void:
	# 退出：等待所有 worker 任务完成后再释放，否则 worker 完成时 call_deferred
	# 会打到已释放实例（"Cannot call method 'call_deferred' on a previously freed instance"）。
	_exiting = true
	_cancel_async()
	# 粗层 worker 的任务 ID 与在途状态都在视点层，由它统一置停 + wait（必须在释放节点前）。
	# paged_layer 是子节点，`_exit_tree` 会自己 abort；这里显式再调一次是幂等的，
	# 但顺序很关键：必须在本类释放 _lod_meshes 之前完成 wait。
	if paged_layer != null:
		paged_layer.abort()
	infinite_layer.abort()
	_clear_lod_meshes()


# [INF] 视点相关
## 取消尚未完成的异步网格生成任务。
## 批次自己负责结算：cancel() 释放只读快照并停止发射结果，wait_tasks() 保证 worker
## 在节点释放前全部结束（否则其 call_deferred 会打到已释放实例）。
func _cancel_async() -> void:
	# 【必须先取局部引用】Signal 的 emit 是**同步**的：cancel() 内部 _finish() 会 emit
	# finished，进而同步回调 _on_batch_finished 把 _batch 置空。若之后仍用 `_batch.xxx`，
	# 就会在 null 上调用 → "Nonexistent function 'wait_tasks' in base 'Nil'"。
	# （只有"_exit_tree 时批次仍在途"才触发，故长期潜伏：正常游玩极少命中。）
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

	# 【唯一的分叉】绘制模式决定走哪条路径。两条路径共用同一个几何内核。
	if draw_mode == DrawMode.STATIC:
		# STATIC 不预先派生材质快照：它走共享缓存，材质只由**第一个**构建者生成一次
		# （见 _rebuild_static 的 builder）。若在这里无条件调 _materials.surfaces()，
		# 100 个实例会各自生成一遍 4 张 256×1 纹理（实测 100 实例多花 400ms，纯浪费）。
		_rebuild_static()
		return

	# DYNAMIC：纹理材质与材质快照都走唯一缓存（材质变化时需手动调用 regenerate_materials 作废）：
	# 快照只在作废后深拷贝一次，供异步子线程安全读取，体素变化不触发大对象拷贝。
	_materials.surfaces(data.materials)
	_materials.snapshot(data.materials)
	# 统一走异步生成（CHUNK_ASYNC 为唯一路径；同步渲染路径已移除简化）
	_update_mesh_async()


## STATIC 模式：整份模型 → 1 个 ArrayMesh（≤2 surface）挂在本节点自己的 mesh 上。
##
## 【为什么这样最省】`generate_arrays_from_chunks_native` 在 C++ 里一次做完
## 「分 chunk + 构建 34³ 光环 + 面生成 + 合并 + 索引偏移」，GDScript 侧零循环。
## 实测产出的三角形数与导入器 `VoxelMeshGenerator.generate_mesh` **逐个模型精确相同**
## （deer 1344 / cars 4638 / teapot1 39648）——即 STATIC 的产物在几何上与"导入成 ArrayMesh"
## 完全等价，只是数据来源是活体素。
##
## 【关键：走共享缓存】收益来自"多实例共享同一份 mesh 资源 → 引擎自动合批"。
## 每个实例各建一份等于白做（实测 deer×100：各自一份 532 draw / 10fps，共享 5 draw）。
## 见 VoxelMesher.acquire_shared_mesh 的注释。
##
## 代价：改一个体素要重建整份（实测 deer 1.6~3.1ms / cars 7.4~9.3ms / teapot1 85ms）。
## 这正是 DrawMode 存在的原因 —— 要频繁编辑就切 DYNAMIC。
func _rebuild_static() -> void:
	_cancel_async()          # STATIC 不用异步批次，清掉可能残留的 DYNAMIC 任务
	# 【为什么用 Dictionary 接住而不是普通局部变量】GDScript 的 lambda **按值捕获**局部变量，
	# 在闭包里赋值改不到外层（实测 last_solid_vertices 恒为 0）。Dictionary 是引用类型，
	# 往它的槽位里写才对外可见。缓存命中时 builder 不执行 → 槽位保持空，故下面要判空。
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
		# （顶点/法线/UV/索引全部重建），teapot1 一次 6.25ms —— 纯粹为了填诊断字段而
		# 在建立网格的同一帧再拷一遍几何。改用已算好的 arrays 直接读尺寸：零拷贝。
		var solid_v := (built_arrays.get("solid_verts", PackedVector3Array()) as PackedVector3Array).size()
		var trans_v := (built_arrays.get("trans_verts", PackedVector3Array()) as PackedVector3Array).size()
		_set_last_vertex_stats(solid_v, trans_v, data.get_all_chunk_keys().size())
	mesh_updated.emit()



## chunk 的世界空间 AABB（统一实现见 VoxelWorldUtil，此处转发供内部旧调用复用）
static func _chunk_world_aabb(ck: Vector3i, chunk_size_world: float, world_offset: Vector3) -> AABB:
	return VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)


## 相机到 chunk 中心的距离（统一实现见 VoxelWorldUtil，chunk/流式距离判定统一走此接口）
static func _chunk_center_dist(ck: Vector3i, cam_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> float:
	return VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset)


## AABB 是否有任意顶点在视锥内（统一实现见 VoxelWorldUtil）
static func _aabb_has_vertex_in_frustum(aabb: AABB, cam: Camera3D) -> bool:
	return VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam)


## 世界坐标 → chunk key（统一实现见 VoxelWorldUtil）
static func _chunk_from_world(world_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> Vector3i:
	return VoxelWorldUtil.chunk_from_world(world_pos, chunk_size_world, world_offset)


static func _is_chunk_beyond_unload(ck: Vector3i, cam: Camera3D, chunk_size_world: float, world_offset: Vector3, unload_d: float) -> bool:
	if cam == null or unload_d <= 0.0:
		return false
	return _chunk_center_dist(ck, cam.global_position, chunk_size_world, world_offset) > unload_d


## origin shift 后平移**渲染层**：所有网格节点 key 平移 + 节点 position 更新 + 各类集合字典 key 平移。
## 由无限层在判定需要平移后调用（何时平移是视点逻辑，归无限层；平移哪些账本是内核私有状态）。
## 【为什么整体平移而不让无限层逐个来改】下面 10+ 个字典全是内核私有渲染层状态，
## 逐个开访问器等于把内核内部结构泄漏出去；一个整体入口反而是更窄的接口。
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
	# 其中 typed dict 需 typed 构建，故就地累加）。延迟队列 / 强制标记 / 粗层调度账本
	# 全归无限层，由它自行 shift_keys（内核不碰它的账本，见 VoxelInfiniteLayer.shift_keys）。
	_mesh_build_queue = VoxelChunk.shift_key_dict(_mesh_build_queue, shift)
	# 分组账本与 chunk 几何缓存同样按键平移（不平移会让在途组指向旧坐标）
	if group_shift > 0:
		_group_meshes = VoxelChunk.shift_key_dict(_group_meshes, shift)
		_group_dirty = VoxelChunk.shift_key_dict(_group_dirty, shift)
	_chunk_arrays = VoxelChunk.shift_key_dict(_chunk_arrays, shift)
	# 碰撞账本归协作组件：它自己的键与节点位置由它按同一个 shift 平移。
	if _collision != null:
		_collision.on_origin_shift(shift, chunk_size_world)
	# 子类钩子：本类只平移**渲染层**状态。子类若持有体素坐标队列（破坏系统的待移除 /
	# 级联 / 待生成掉落体等），必须在此同步平移，否则在途操作会打到平移后的错位体素。
	on_origin_shift(shift)


## origin shift 完成后的子类钩子（默认空实现）。
## 只开一个定点钩子，而不让子类 override shift_render：后者要连带复制上面整套渲染层
## 平移逻辑（网格节点、碰撞体、各 block 级账本），漏一处就是幽灵节点/幽灵碰撞体。
func on_origin_shift(_shift: Vector3i) -> void:
	pass


# 多层级 LOD 渲染（lod_count 控制层级数，view_distance 自动等比 ×2 分带）
#   LOD0 全精度 chunk（level 0 block == chunk）；LOD i 大块每格 2^i 体素。
#   分带：LOD_i 显示区 = [outer[i-1], outer[i]]（outer[i] = view_distance / 2^(lod_count-1-i)）。
#   各层 block 生成/移除/可见性带滞回 margin，交界处内层未就绪时用外层兜底防空洞。



# ── LOD 网格账本 API（无限层经此读写）────────────────────────────────────────
# 账本 index 直接 = LOD 层级（0 = 全精度 chunk，>=1 = 粗层大块）。
# 有意只开"按键存取"的窄访问器，不暴露整表引用 —— 与既有的 has_chunk_mesh 同一风格，
# 既让无限层拿得到所需，又不把内核的私有结构泄漏出去（对比 shift_render 的整体入口）。

## 该层该 block 是否有条目（含"空标记"null —— 表示确定无体素、停止重复派发）
func has_lod_mesh(level: int, bk: Vector3i) -> bool:
	return level >= 0 and level < _lod_meshes.size() and _lod_meshes[level].has(bk)


## 取该层该 block 的网格节点；返回 null = 无条目或"空标记"（判定"是否已就绪"时两者同义）
func lod_mesh(level: int, bk: Vector3i) -> MeshInstance3D:
	if level < 0 or level >= _lod_meshes.size():
		return null
	return _lod_meshes[level].get(bk)


## 该层全部 block key 快照（无限层遍历用）。返回新数组，调用方在遍历中改动账本也安全。
func lod_mesh_keys(level: int) -> Array:
	if level < 0 or level >= _lod_meshes.size():
		return []
	return _lod_meshes[level].keys()


## 标记该 block"确定空"（无体素）：保留条目但置 null
func mark_lod_block_empty(level: int, bk: Vector3i) -> void:
	if level >= 0 and level < _lod_meshes.size():
		_lod_meshes[level][bk] = null


## 主线程挂载粗 LOD 大块网格（mesh 已由工作线程构建，此处仅建节点 + 赋材质 + 挂载，很轻）
## 失效重建时复用已有节点（直接替换 mesh，避免节点销毁/重建造成闪烁）
func mount_lod_mesh(level: int, bk: Vector3i, mesh: ArrayMesh) -> void:
	if level < 0 or level >= _lod_meshes.size():
		return
	var mi: MeshInstance3D = _lod_meshes[level].get(bk)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "LOD%dB_%d_%d_%d" % [level, bk.x, bk.y, bk.z]
		add_child(mi)
		# 新建的节点默认可见 —— 粒子模式下必须立刻隐藏，否则会和粒子同屏
		# （见 _meshes_should_be_visible 的注释：切换时账本可能还是空的）
		mi.visible = _meshes_should_be_visible()
		mi.position = Vector3(bk) * _lod_block_edge_world(level)
	if mesh != null and mesh.get_surface_count() > 0:
		_apply_materials(mesh)
		mi.mesh = mesh
	_lod_meshes[level][bk] = mi


## 释放某层某 block 的网格节点并移除条目（粗层的调度账本归无限层，由它自己清）
## level 0（chunk）不走这里 —— LOD0 的移除是 remove_chunk_mesh（含碰撞与延迟队列，语义不同）
func clear_lod_mesh(level: int, bk: Vector3i) -> void:
	if level < 1 or level >= _lod_meshes.size():
		return
	var mi = _lod_meshes[level].get(bk)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[level].erase(bk)


## 该 chunk 是否在构建队列中（无限层判定"内层是否就绪"用）
func is_mesh_build_queued(ck: Vector3i) -> bool:
	return _mesh_build_queue.has(ck)


## 取（必要时重建）某 LOD 层的材质对齐数组：层级 → 体素材质 id 数组
## force=true 用于"材质或层数已变"的场景（内核在派发前与失效时调用）
func lod_materials(level: int, force: bool = false) -> Array:
	if data == null:
		return []
	if force:
		return _materials.rebuild_aligned(data.materials, level)
	return _materials.aligned(data.materials, level)


## 取渲染用的运行时 Material 对象数组（表面 0/1）。
## 走唯一材质缓存 `_materials`：源引用变化或 regenerate_materials 时自动作废，
## 故表现层（掉落块 mesh）与渲染层共用同一份 Material 对象，无需各自再建一份。
func surface_materials() -> Array:
	return _materials.surfaces(data.materials) if data else []




## 清除单个 chunk 的渲染网格（释放 mesh + 碰撞 + 相关队列条目）。两类调用场景：
##   · 数据层已变空但渲染层 mesh 残留：破坏/崩塌后 chunk 内体素全被移除（has_chunk=false），
##     增量重建时 infinite_layer.filter_visible_chunks 会跳过空 chunk 不派发 → 不主动清除则旧 mesh 残留
##     （视觉上"悬空块还在"，数据其实已掉）；
##   · 流式卸载：超出距离直接释放网格（重进范围由统一流式扫描按 can_supply_chunk 重新补建）。
## 【数据层不在此卸载】本函数只管渲染网格；数据层卸载由流式卸载段单独按更外扩的半径调
## QVoxelSource.unload_chunk()（见 VoxelInfiniteLayer.lod0_data_unload_d）——网格半径与数据半径分开，
## 是因为粗层降采样还需要比网格更远一圈的 LOD0 数据。
func remove_chunk_mesh(ck: Vector3i) -> void:
	var mi: MeshInstance3D = _lod_meshes[0].get(ck)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[0].erase(ck)
	if _collision != null:
		_collision.remove(ck)
	_mesh_build_queue.erase(ck)
	# 该 chunk 的重建权随网格移除作废（否则延迟队列里残留"幽灵补建"条目）
	if uses_paged_layer():
		paged_layer.on_mesh_removed(ck)
	infinite_layer.on_mesh_removed(ck)


## 异步路径：后台线程生成网格数据，完成后通过 call_deferred 直接传递结果到主线程
## 主线程绝不阻塞：旧任务未完成时直接启动新任务覆盖，子线程完成后检查 gen_id 丢弃过期结果
func _update_mesh_async() -> void:
	# 若旧任务已完成但还未轮询应用（极端情况），不阻塞，直接启动新任务覆盖
	# 旧任务子线程完成后会因 gen_id 不匹配而不写入结果（自然丢弃）

	# 【密集光环快照方案】不为每个 chunk 提取字典切片，而是让 QVoxelSource 直接从其
	# dense chunk 缓冲构建 34³ 密集"光环"（chunk + 1 体素外缘，PackedInt32Array）。
	# 每个子线程只读取自己那个私有的光环快照；快照是独立字典，主线程后续对字典的
	# 增删不与之冲突。注意快照与活动缓冲**共享底层**：GDScript 的逐元素写不会触发
	# 写时拷贝，故批次在途期间用 QVoxelSource 的只读快照计数把单点写降级为显式拷贝
	# （见 begin_readonly_snapshot），杜绝数据竞态（块随机显示/隐藏的根因）。
	var rebuild_chunks: Array[Vector3i] = []
	# chunk 级脏标记（_mark_voxel_dirty 已含跨界面的边界邻居）：
	# 大崩塌移除不再主线程逐体素写 dict
	rebuild_chunks = data.get_dirty_chunks()
	var had_dirty := not rebuild_chunks.is_empty()
	# 【防闪】剔除"源已作废、等待重新取数"的 chunk：作废后其缓冲为空，拿空快照重建会把
	# 还看得见的网格抹掉、再异步重建 —— 这就是"改一下模型闪一下"的根因。它们的重建权交给
	# 流式泵（QVoxelSource.pending regeneration）：重新取数回填时 _accept_chunk_buffer 会再次
	# 标脏，届时缓冲已就绪、重建即正确。清理分支因此也不会释放这类 chunk 的网格。
	if not rebuild_chunks.is_empty():
		var keep: Array[Vector3i] = []
		for ck in rebuild_chunks:
			if not data._is_chunk_source_invalidated(ck):
				keep.append(ck)
		rebuild_chunks = keep
	# 【流式防抖】剔除已在延迟补建队列的脏 chunk：其重建权归无限层的延迟队列
	# （晋升时 process_deferred_chunks 重新 mark_chunk_dirty，且未来构建的快照必含
	# 已到达的邻居数据，无需边界缝合标记）。否则流式波次中每个新到 chunk 都把视锥外
	# 的延迟邻居重新标脏 → 每帧一轮"脏N→视锥内0→再延迟"空转：gen_id 无限递增、
	# 枚举+视锥判定每帧照付、永不收敛（STREAMING 大波次主线程卡顿的根源）。
	var dropped := 0
	var view_layer := paged_layer if uses_paged_layer() else null
	if view_layer != null:
		if not view_layer.deferred_is_empty():
			for i in range(rebuild_chunks.size() - 1, -1, -1):
				if view_layer.is_deferred(rebuild_chunks[i]):
					rebuild_chunks.remove_at(i)
					dropped += 1
	elif not infinite_layer.deferred_is_empty():
		for i in range(rebuild_chunks.size() - 1, -1, -1):
			if infinite_layer.is_deferred(rebuild_chunks[i]):
				rebuild_chunks.remove_at(i)
				dropped += 1
	if diag_enabled and dropped > 0:
		print("[诊断] 增量重建防抖: 剔除已在延迟队列的脏 chunk %d 个" % dropped)
	# 限量批次：超过上限的放回 dirty（下帧续建）。回原点/大崩塌时 dirty 可上千，
	# 单帧全量快照 + 派发上千 worker → 主线程阻塞（update_mesh 数百 ms → 帧率个位数）。
	# 分批后每帧快照/派发量受限，网格经 _process_mesh_build_queue 平滑上传。
	if rebuild_chunks.size() > _rebuild_batch_limit:
		for i in range(_rebuild_batch_limit, rebuild_chunks.size()):
			data.mark_chunk_dirty(rebuild_chunks[i])
		rebuild_chunks.resize(_rebuild_batch_limit)
		# 放回剩余 dirty 后必须重新置位：_update_mesh 开头会清 _dirty，
		# 若不重新 request_update，剩余 dirty 将永久卡住 → 初始构建/大批量
		# 重建只生成第一批，其余 chunk 网格缺失（破坏demo初始只显示一个小角落、
		# 流式demo脚底下不显示）。置位后下帧 _process 继续消费下一批。
		request_update()
	# 有脏标记但全部已在延迟队列 → 本帧无生产性工作：不递增 gen_id、不派发任务、
	# 不再触发下一帧（延迟队列晋升补建时自会标脏触发），杜绝空转轮次。
	if rebuild_chunks.is_empty() and had_dirty:
		return
	# 材质快照复用缓存（仅在材质变化时深拷贝），避免每帧大对象深拷贝
	var snapshot_materials := _materials.snapshot(data.materials)
	# 一次对齐材质供所有 per-chunk worker 复用，避免每个任务重复 align_by_id
	# （生成器内部要求"数组索引==材质ID"，对齐后可 O(1) 按 ID 取材质）
	var aligned_materials := VoxelMaterial.align_by_id(snapshot_materials)
	# 透明标志表按批次算一次（逐块重建要扫一遍材质表，批量重建时纯属重复劳动）
	var trans_flags := VoxelMaterial.build_trans_flags(aligned_materials)
	# 渲染居中偏移（体素单位），子线程无权访问节点，随任务参数传入
	var render_offset: Vector3 = data.center_offset if data else Vector3.ZERO

	# 后台线程生成纯数据（线程安全，不触碰 ArrayMesh）
	# 将 voxel_scale 等渲染参数作为任务参数传入，避免子线程访问节点属性
	# 每个脏 chunk 独立一个线程任务，WorkerThreadPool 内部管理并发数
	# per-chunk 异步生成（唯一网格路径）
	# 可见性决策：全量走所有 chunk；增量先清除"已变空"chunk 的残留 mesh 再决策。
	# 两分支决策不同，但下方"快照预算 + 派发"完全一致，合并到一处。
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
		# 【关键】先清除"已变空"chunk 的残留 mesh：破坏/崩塌后 chunk 内体素
		# 全被移除（has_chunk=false），而 infinite_layer.filter_visible_chunks 会跳过空 chunk
		# 不派发重建 → 若不主动清除，旧 mesh 残留，视觉上"悬空块还在"（数据其实已掉）。
		for ck in rebuild_chunks:
			if _lod_meshes[0].has(ck) and not data.has_chunk(ck):
				remove_chunk_mesh(ck)
		# 统一可见性决策（流式距离 + 视锥/近处全向）
		visible = _filter_visible(rebuild_chunks)
		if diag_enabled:
			print("[诊断] 增量重建: 脏%d Chunk, 视锥内%d, 延迟%d" % [rebuild_chunks.size(), visible.size(), rebuild_chunks.size() - visible.size()])
	# 本帧渲染批次：任务计数与只读快照句柄都由它持有，结算点唯一（见 VoxelMeshBatch）。
	# 结果处理里任何提前 return 都不可能再让计数失衡——这正是"双重递减击穿 COW"的根治。
	var batch := VoxelMeshBatch.new()
	batch.result_ready.connect(_on_batch_result.bind(batch))
	batch.finished.connect(_on_batch_finished.bind(batch))
	_batch = batch
	# 快照预算：超预算尾部放回 dirty 下帧续建（_update_mesh 开头清 _dirty，须重置位），
	# 避免初始/切换模式一帧全量快照尖峰。
	# 声明"只读快照"：快照与活动缓冲共享底层，而 GDScript 的逐元素写不会触发写时拷贝，
	# 故本批次在途期间主线程的单点写必须先在目标缓冲上分叉（见 QVoxelSource.begin_readonly_snapshot）。
	# 句柄交给批次，由它在结算（完成 / 取消）时唯一一次释放。
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
	# voxel_scale / render_offset / diag_enabled 原先是在 lambda 里直接读节点属性，
	# 属于违反约定（虽然读一个 float 实际不会崩，但会被后续改动踩成真竞态）。
	# lambda 按值捕获局部变量，跨线程安全。
	var w_scale := voxel_scale
	var w_offset := render_offset
	var w_diag := diag_enabled
	# 形状参数同样按值捕获（worker 不能读节点属性）
	var w_shape := int(voxel_shape)
	var w_subdiv := sphere_subdivisions
	var w_sphere_scale := sphere_scale
	for ck in visible:
		# 【必须用 lambda 显式绑定 out 的位置】Godot 4 的 Callable.bind() 把绑定实参放在
		# call() 实参**之后**，所以 `_generate_chunk_worker.bind(args...).call(out)` 会让 out
		# 落到第 1 个形参上、其余参数整体错位（曾因此报 "Cannot convert argument 2 from
		# Dictionary to Array"）。旧代码用 add_task(bind(...)) 时没有额外实参，故掩盖了这一点。
		# 下面的 lambda 只有一个自由形参 out，与 VoxelMeshBatch._wrap 的调用方式严格对应。
		batch.spawn(func(out: Dictionary) -> void:
			_generate_chunk_worker(snapshot, aligned_materials, trans_flags, ck,
				w_scale, w_offset, w_diag, out, w_shape, w_subdiv, w_sphere_scale))
	# 一个任务都没派发出去时必须立即结算：否则 _batch 永远"在途"，会挡住后续所有更新
	# （旧实现用裸计数 0 天然表示"无在途"，换成对象后要显式结清）。
	batch.settle_if_idle()


## 可见 chunk halo 快照的每帧毫秒预算：常规 6ms；可见集超过 _rebuild_batch_limit 时放宽到 10ms
const _SNAPSHOT_BUDGET_MS := 6.0
const _SNAPSHOT_BUDGET_MS_LARGE := 10.0


## 可见 chunk 的 halo 快照（毫秒预算版）：逐片快照、超预算即止。
## 原生 snapshot_chunks_halo 会自动外扩 27 邻居，故切片不产生边界洞。
## 实测单 chunk 约 0.31ms（带流、邻居从盘重载），整批远小于预算。
## 返回 {snapshot: Dictionary(ck -> 缓冲), taken: int}；未快照尾部由调用方放回 dirty。
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
## 都通过 _make_result 构建结果，消费方 _apply_single_chunk_result 统一按键读取。
## chunk_key 缺省为 (-999,-999,-999) 表示"非单chunk结果"（全量结果）。
## 不含 gen_id：过期判定已由 VoxelMeshBatch 的对象身份承担（取消即不再发射结果）。
static func _make_result(arrays: Variant, gen_time_ms: float, solid_vertices: int,
		trans_vertices: int, total_chunks: int, affected_count: int,
		chunk_key: Vector3i = Vector3i(-999, -999, -999)) -> Dictionary:
	return {
		"arrays": arrays,
		"chunk_key": chunk_key,
		"gen_time_ms": gen_time_ms,
		"solid_vertices": solid_vertices,
		"trans_vertices": trans_vertices,
		"total_chunks": total_chunks,
		"affected_count": affected_count,
	}


## 以顶点计数更新 last_* 统计字段（实心/透明三角形 = 顶点数 / 3）
func _set_last_vertex_stats(solid_vertices: int, trans_vertices: int, total_chunks: int) -> void:
	last_solid_vertices = solid_vertices
	last_trans_vertices = trans_vertices
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
## 主线程通过 _process 轮询 WorkerThreadPool.is_task_completed 后读取，保证线程安全
## 注意：此函数在子线程中运行，不能访问除参数外的节点属性！
## diag_enabled 由主线程派发时捕获传入，子线程只读参数，避免跨线程访问节点属性
## 单 chunk 工作线程入口：每个脏 chunk 独立一个线程任务，真正并行处理
## 每个 chunk 独立生成网格数据，结果由 VoxelMeshBatch 统一回传并结算
## 注意：此函数在子线程中运行，不能访问除参数外的节点属性！
## buffers 为主线程派发时一次性构建的"受影响区域"chunk 缓冲快照（深拷贝字典），
## worker 在子线程内据此构建自己的 18³ halo（纯只读，无数据竞态），
## 避免主线程逐 chunk 提取 halo 造成秒级阻塞（旧方案）。
## materials 参数为已按 ID 对齐的材质数组（主线程派发时一次对齐，worker 复用避免重复开销）
## diag_enabled 由主线程派发时捕获传入，子线程只读参数，避免跨线程访问节点属性
func _generate_chunk_worker(buffers: Dictionary, materials: Array, trans_flags: PackedByteArray,
		chunk_key: Vector3i, scale: float, offset: Vector3 = Vector3.ZERO,
		diag_enabled: bool = false, out: Dictionary = {},
		shape: int = VoxelShape.CUBE, subdivisions: int = 0, sphere_scale_v: float = 1.0) -> void:
	var t0 := Time.get_ticks_usec()
	var halo := VoxelChunkGenerator.build_halo_from_buffers(buffers, chunk_key)
	var arr: Dictionary
	if shape == VoxelShape.SPHERE:
		# 球体路径：每体素一颗小球。顶点在 **chunk 局部空间**（与方块路径同一约定），
		# 由 _apply_built_chunk 里的 chunk_mesh.position 定位到世界。
		# 【offset 必须传】与方块路径同一约定（顶点 = (体素坐标 + offset) × scale）。
		# 漏掉它会让球体整体偏一个模型尺寸 —— 正是"球模式与其它形态位置对不上"的原因。
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

	# 构建结果字典（统一契约 _make_result，含 chunk_key 供 _apply_single_chunk_result 识别单个 chunk）
	var arrays := {}
	if has_data:
		arrays[chunk_key] = arr
	# 结果写进 out（由 VoxelMeshBatch 传入）：回传与计数结算都由批次负责。
	# 本函数不再自己 call_deferred —— 那会让"结果回传"与"计数递减"分处两地，
	# 正是旧实现计数失衡的来源。
	out.merge(_make_result(arrays, gen_time_ms, sv, tv, 1 if has_data else 0, 1, chunk_key))


## 主线程结果处理入口（由 VoxelMeshBatch 在主线程发射）。
## **本函数不碰计数**：结算在批次内部唯一一处完成，故这里的任何提前 return
## 都不可能让批次失衡（旧实现正是在这里与两条早退路径各减一次 → 双重递减）。
## batch 由信号 bind 传入：batch != _batch 即说明已被换批 / 取消，结果过期。
## 收尾仍延迟到下一帧（_on_batch_finished 置 _batch_complete_pending），
## 避免"最后一个任务完成"瞬间在主线程做重活造成帧尖峰（曾观测到 83ms）。
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
## 仅"真的派发过任务"的批次才置收尾标志 —— 空批次等价于旧实现的裸计数 0，不做任何收尾。
func _on_batch_finished(batch: VoxelMeshBatch) -> void:
	if batch != _batch:
		return
	_batch = null
	if batch.has_dispatched():
		_batch_complete_pending = true


## 应用单个 chunk 的异步结果（在主线程 _process 中调用）
## 结果恒为单 chunk（per-chunk 生成），直接更新对应子 MeshInstance3D
func _apply_single_chunk_result(result: Dictionary) -> void:
	var _diag_t0 := Time.get_ticks_usec()
	var _t_get_chunk := 0.0
	var arrays = result.get("arrays", {})
	var chunk_key: Vector3i = result.get("chunk_key", Vector3i(-999, -999, -999))
	var gen_time_ms = result.get("gen_time_ms", 0.0) as float

	# 更新统计信息（统一契约 _apply_stats_from_result）
	_apply_stats_from_result(result)
	last_rebuild_affected_count = 1
	last_rebuild_chunk_count = 1

	# 单 chunk 结果（来自 _generate_chunk_worker）
	if chunk_key.x != -999:
		# 流式：结果回来时 chunk 仍超出卸载距离（相机快速远离）→ 丢弃过期结果，
		# 避免卸载后的旧网格/旧数据复活。
		# 直接按【当前距离】判断（不依赖残留标记）：相机重新走近（<unload）的 chunk
		# 必须应用结果，否则永久缺失。
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
		# 否则释放后异步 mesh 结果回来仍建网格 → 地块"显示→消失→再显示"闪烁。
		if data and data.node != null and not has_voxels_in_data:
			# 同上：结果过期丢弃，不碰计数
			return

		# 入队待构建（GPU 上传限流，_process 每帧批量处理）
		# 避免连续破坏时一帧大量 ArrayMesh 创建 + GPU 上传 → Metal fence 超时
		_mesh_build_queue[chunk_key] = {
			"arrays": arr if (arr is Dictionary and not arr.is_empty() and has_voxels_in_data) else {},
			"has_voxels": has_voxels_in_data,
		}
		_record_perf_stats(1, gen_time_ms, _t_get_chunk)

	# 诊断：单 chunk 应用耗时 > 1ms 时打印（顺带把实测应用耗时写进公开统计字段）
	var _t_apply_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	last_apply_time_ms = _t_apply_ms
	if diag_enabled and _t_apply_ms > 1.0 and chunk_key.x != -999:
		print("[诊断] _apply_single_chunk_result: Chunk%s, get_chunk=%.2fms, 总=%.2fms" % [chunk_key, _t_get_chunk, _t_apply_ms])


# GPU 上传限流（批量构建队列）
# 用 call_deferred 在帧尾执行，避开渲染循环内的 GPU 竞争；每帧限量构建。

## mesh 组装（同步 GPU 上传）的每帧时间预算与数量上限：常规 3ms / _mesh_build_per_frame；
## 大量破坏（脏 chunk 多于 _mesh_build_per_frame）时放宽到 8ms / 24，降低 mesh 更新延迟感。
const _MESH_BUILD_BUDGET_MS := 3.0
const _MESH_BUILD_BUDGET_MS_BURST := 8.0
const _MESH_BUILD_BURST_COUNT := 24


## 每帧从构建队列取一批 chunk 构建 mesh（GPU 上传限流）。
## 连续破坏时大量异步结果回主线程，若每帧全部立即 build_mesh_from_arrays（同步 GPU 上传），
## Metal 驱动 fence 等待会超时。改为帧尾限量构建，把 GPU 上传摊平到多帧。
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
	# 用"分组两趟"而非自定义比较器："已有优先"不构成严格弱序，sort_custom 要求合法比较器。
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
	# 【不能】在此 call_deferred 自续调度——MessageQueue.flush 会把 flush 期间新推入的
	# 调用在同帧继续执行，自续 = 同帧反复进本函数（每次 budget 个/3ms 直至清空积压），
	# 流式波次期几十个 worker 结果回主线程时整队一帧打穿，数量+毫秒限流双双失效。
	if diag_enabled and built > 0:
		print("[诊断] GPU上传批处理: %d chunk, 耗时%.2f ms, 剩余%d" % [
			built, (Time.get_ticks_usec() - t0) / 1000.0, _mesh_build_queue.size()])


## 统一可见性决策分叉（全量构建与增量重建共用）。
## 【为什么要有这个薄壳】"该问谁"必须收在一处：`paged_layer` 接管后走它的 `filter_chunks`，
## 否则走旧层。若在几个调用点各写一遍 `if paged_layer`，漏掉任何一处就表现为
## "流式/视锥在其中一条路径失效"——这种 bug 只在特定构建时机出现，极难复现定位。
func _filter_visible(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if uses_paged_layer():
		return paged_layer.filter_chunks(chunks)
	return infinite_layer.filter_visible_chunks(chunks)


## 视点层上报"相机距离"用的卸载半径（供旧调用点复用）。
func _view_unload_d() -> float:
	if uses_paged_layer():
		return paged_layer.unload_d()
	return infinite_layer.unload_d()


## 各 LOD 层外半径（分带表）。
func _view_lod_outer() -> Array[float]:
	if uses_paged_layer():
		return paged_layer.lod_outer()
	return infinite_layer.lod_outer()


## 粗 LOD 大块 mesh 帧尾挂载（deferred 转发目标）。
func _flush_lod_mesh_apply_queue() -> void:
	if uses_paged_layer():
		paged_layer.process_lod_mesh_apply_queue()
	else:
		infinite_layer.process_lod_mesh_apply_queue()


## 给 ArrayMesh 的两个表面赋材质（实心/透明）。chunk/LOD1/碎片应用统一走此辅助。
func _apply_materials(new_mesh: ArrayMesh) -> void:
	var mats := _materials.surfaces(data.materials) if data else []
	if new_mesh and mats.size() >= 2:
		if new_mesh.get_surface_count() > 0 and mats[0]:
			new_mesh.surface_set_material(0, mats[0])
		if new_mesh.get_surface_count() > 1 and mats[1]:
			new_mesh.surface_set_material(1, mats[1])


## 应用单个待构建 chunk（构建 mesh + 挂载节点 + 更新碰撞）
func _apply_built_chunk(chunk_key: Vector3i, entry: Dictionary) -> void:
	# 带外校验：破坏/编辑不应让超出 LOD0 带的 chunk 临时挂载（否则粗层区破坏时
	# LOD0 细网格"闪现"后被移除 → 与粗层交替闪烁）。粗层区破坏由粗层 mesh 反映，
	# LOD0 chunk 只挂载带内；此处与 _process_chunk_level 的移除判定保持一致。
	#
	# 【必须跳过 FULL】FULL 的语义是"全量生成所有 chunk"。此前这里没有 FULL 判断，
	# 于是 lod_outer[0]（= view_distance，默认 40）之外的 chunk 会被**静默丢弃**：
	# 不挂载、不报错、不告警。实测 deer×400 在 FULL 下只挂上 418/1600 个 chunk，
	# 而调用方等网格就绪会一直等到超时。这是"最简路径被 LOD 机器咬了一口"的典型。
	# DYNAMIC 之外的 STATIC 也不可能走到这里（STATIC 不走异步批次），但一并早退最稳。
	if draw_mode != DrawMode.DYNAMIC or visibility_mode == VisibilityMode.FULL:
		pass
	else:
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

	# 【DYNAMIC 分组路径】group_shift > 0 时绘制单元是 **group** 而不是 chunk。
	# worker 已经（在子线程里、带着 34³ 光环）算好了这个 chunk 的正确几何 ——
	# 包括跨 chunk 边界的面可见性。所以这里**不重新生成**，只把它缓存下来，
	# 再把所属 group 标脏；帧尾的 _rebuild_group_meshes 只做纯拼接（顶点平移 + 索引偏移）。
	#
	# 【踩过的坑】第一版在这里丢掉 arr 只标脏，帧尾用 VoxelMesher.build_group 从头从体素
	# 重新生成整个组 → 几何算两遍 + 第二遍在主线程 → destruction_demo（196 chunk / 32 组）
	# 模型长期显示不全，water_sim 一旦有随机事件就掉帧。这条注释存在的意义就是防止那样写。
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
		var new_mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
		_apply_materials(new_mesh)
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
## 每组一个 MeshInstance3D，位置 = 组原点 × 组的世界边长；组内各 chunk 的顶点在这里按
## "相对组原点的偏移"平移后拼起来。
##
## 【关键：纯拼接，不生成几何】数据全部来自 `_chunk_arrays`（worker 在子线程已经算好的
## 每 chunk 几何）。实测单组拼装 < 0.1ms（对比：重新生成的版本是 2~8ms）。
## 这就是"分组模式不该比 per-chunk 慢"的保证 —— 两条路径的几何生成完全相同，只是拼装粒度不同。
func _rebuild_group_meshes(budget_n: int) -> void:
	if _group_dirty.is_empty():
		return
	var mats := _materials.surfaces(data.materials)
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
			built += 1
			continue
		var new_mesh := VoxelMesher.to_mesh(merged, mats)
		if new_mesh == null:
			if node != null and is_instance_valid(node):
				node.queue_free()
			_group_meshes.erase(gk)
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
		built += 1
		if (Time.get_ticks_usec() - t0) / 1000.0 > _MESH_BUILD_BUDGET_MS_BURST:
			break
	if diag_enabled and built > 0:
		print("[诊断] DYNAMIC 整组拼装: %d 组, 耗时%.2f ms, 剩余%d"
				% [built, (Time.get_ticks_usec() - t0) / 1000.0, _group_dirty.size()])


## 批次完成清理：当所有任务都完成后执行
## 处理 _pending_retrigger 并发出 mesh_updated 信号
## 空 Chunk 清理已在 _apply_single_chunk_result 中增量完成，无需全量遍历
func _on_batch_complete() -> void:
	# 只读快照已由 VoxelMeshBatch 在结算时释放，此处无需再配对释放。
	# 处理 _pending_retrigger（极少情况下被外部设置）
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
## 分工：粗层的调度账本（待办 / 重建 / 代次 / 重试 / 挂载队列 / 延迟队列）归视点层，
## 由它一并清空；本类只清自己的网格账本、构建队列与材质对齐缓存。
func _clear_lod_meshes() -> void:
	if paged_layer != null:
		paged_layer.clear_lod_state()
	infinite_layer.clear_lod_state()
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
