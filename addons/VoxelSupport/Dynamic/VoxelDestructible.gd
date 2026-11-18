@tool
class_name VoxelDestructible
extends Node3D

## 动态体素破坏系统 —— **组件形态**：挂在 [VoxelRenderer] 下当子节点，而不是继承它。
##
## 【用法】
## [codeblock]
## var renderer := VoxelRenderer.new()
## renderer.data = data
## renderer.voxel_scale = 0.1
## renderer.draw_mode = VoxelRenderer.DrawMode.DYNAMIC   # 破坏必须 DYNAMIC，见下
## add_child(renderer)
## var destructible := VoxelDestructible.new()
## renderer.add_child(destructible)
## destructible.configure(renderer)   # 可省：_ready 会从父节点惰性取
## destructible.damage_sphere(center, radius)
## [/codeblock]
##
## 【为什么改成组件】继承形态把"渲染"和"破坏"两份职责压进同一个节点：一个节点同时有渲染
## 旋钮与破坏旋钮（48 个 Inspector 属性），破坏系统也就没法只做破坏这一件事。拆成组件后
## 渲染器只管渲染、本组件只管破坏（17 个旋钮），依赖方向单向：本组件 → 宿主。
## 这与仓库里已有的 `VoxelDestructionPresenter`（子节点 + host 引用 + 只读宿主公开面）
## 完全同构；而破坏系统内部本来就是 `VoxelEditKernel` + `VoxelDestructionPresenter` 的组合，
## 这次只是把最外层的继承换成挂节点。
##
## 【宿主必须设 draw_mode = DYNAMIC】本组件直接改 host.data 的体素，而 STATIC 的代价是
## "改一个体素 = 重建整份模型"（实测 cars 22.7ms / teapot1 85ms）；DYNAMIC 只重建受影响的
## chunk（实测 0.4~2ms）。这不是"选个更好的"，而是语义要求：破坏系统存在的意义就是频繁编辑。
## `configure()` 会对非 DYNAMIC 宿主发 push_warning 提醒。
##
## 【依赖方向】本组件 → 宿主：只读宿主公开面（`data` / `voxel_scale` / `infinite_layer` /
## `diag_enabled` / `draw_mode`），渲染与网格重建全部由宿主负责。不碰宿主私有成员
## （与 VoxelDestructionPresenter 同一约定）。
##
## 支持球形/盒形/单体素/射线破坏 + 逐体素健康度 + 悬空崩塌 + 粒子碎片
## 碎片使用 GPU 粒子系统，无物理碰撞体，高性能

## 破坏反馈信号：具体表现（粒子/音效/震动）由游戏自行连接实现
signal voxel_damaged(positions: Array, spawn_debris: bool)      ## 体素被移除时 (含崩塌)
signal voxel_hardened(pos: Vector3i, remaining: float)          ## 体素受伤但未摧毁 (材质硬度未达)（单发，兼容旧用法）
signal voxel_hardened_batch(positions: Array, remaining: Dictionary) ## 批量硬化（帧尾合并发射，避免逐体素高频信号）
signal voxels_about_to_collapse(positions: Array)               ## 悬空体素即将崩塌掉落前

## 【兼容转发信号】宿主渲染器的 `mesh_updated`（网格重建完成）在本组件上重播一次。
## 【为什么必须有】继承形态下 `d.mesh_updated` 就是宿主那个信号，存量调用方（demo 的性能
## 日志）直接 connect 它。组件化后宿主才是信号源，但删掉本声明会让这些调用方在运行期
## 报 "Invalid access to signal" —— 那是最典型的一类静默破坏兼容性问题。
## 绑定时把宿主的信号接到 `_on_host_mesh_updated`，解绑/退出时断开（见 _exit_tree）。
signal mesh_updated


# ── 宿主绑定（组件形态的核心）────────────────────────────────────────────

## 宿主渲染器（只读）。破坏直接改 host.data，渲染与网格重建由宿主负责。
## 由 `configure()` 绑定，或在 `_ready()` 里从父节点惰性取（编辑器里把本组件直接拖到
## VoxelRenderer 下即可，无需写代码）。
var host: VoxelRenderer = null


## 绑定宿主渲染器。重复调用安全（会重新指向新宿主）。
##
## 【为什么强制要求宿主 DYNAMIC，但只警告不自动改】STATIC 下"改一个体素 = 重建整份模型"
## （实测 cars 22.7ms / teapot1 85ms），而破坏系统每次命中都在改体素 —— 那是把 O(chunk)
## 变成 O(模型)，破坏的手感与帧率会一起崩。但自动强制会覆盖用户在 Inspector 里的显式选择，
## 而"静态展示为主 + 偶尔破坏"确实是存在的用法（例如破坏后立刻定格），故只警告。
func configure(host_ref: VoxelRenderer) -> void:
	# 换宿主时先断开旧宿主的信号（reconfigure 场景：demo 重置会重新绑定）
	_unbind_host_signals()
	host = host_ref
	# 表现层也要换宿主：它本身是本组件的子节点，但它的 host 是**渲染器**（要读 voxel_scale /
	# data / infinite_layer）。已在 _presenter 的 getter 里用当前 host 构造，故只在已创建时更新，
	# 避免编辑器里为了传一次引用就白建一个 Node3D。
	if _presenter_impl != null:
		_presenter_impl.host = host_ref
	# 记录当前的数据基准，避免把"绑定前就已发生的 origin shift"误判成一次新平移
	# （否则首次 _process 会把所有在途队列平移到错误的坐标）。
	if host != null:
		_last_origin_chunk = host.infinite_layer.origin_chunk()
	_bind_host_signals()
	_flush_pending_to_host()
	if host != null and host.draw_mode != VoxelRenderer.DrawMode.DYNAMIC:
		push_warning("[VoxelDestructible] 宿主 draw_mode 不是 DYNAMIC：破坏将触发整份模型重建"
				+ "（STATIC 下改一个体素实测 22.7~85ms）。请设 host.draw_mode = VoxelRenderer.DrawMode.DYNAMIC。")


## 订阅宿主的 `mesh_updated`（转发为本组件的同名信号，见 mesh_updated 声明）。
## 用 Callable 比对避免重复连接：configure() 可能被重复调用（幂等要求）。
func _bind_host_signals() -> void:
	if host == null:
		return
	var cb := Callable(self, "_on_host_mesh_updated")
	if not host.mesh_updated.is_connected(cb):
		host.mesh_updated.connect(cb)


## 断开宿主信号（换宿主 / 退出时调用）。
## 【为什么必须断】宿主可能在场景树里活得更久（例如 demo 重置时只换 data 不换宿主），
## 留着连接会让它的信号打到已释放的组件实例上 → "Attempt to call on a freed instance"。
func _unbind_host_signals() -> void:
	if host == null or not is_instance_valid(host):
		return
	var cb := Callable(self, "_on_host_mesh_updated")
	if host.mesh_updated.is_connected(cb):
		host.mesh_updated.disconnect(cb)


## 宿主网格重建完成 → 重播本组件的 mesh_updated（兼容层，见 signal mesh_updated 的注释）。
func _on_host_mesh_updated() -> void:
	mesh_updated.emit()


# ── 【兼容转发】早期本类继承 VoxelRenderer，调用方直接设 `.data` / `.voxel_scale` 等；
# 改成组件后这些属性归宿主。这里转发给 host，让存量调用点不必一次性全改。
# 【为什么不"删干净"】删掉后 `d.data = x` 会变成给节点加一个没人读的哑属性（GDScript 允许
# 这种动态赋值），错误完全静默；转发则让新旧两种写法语义等价。
# 【暂存规则】host 未绑定时写进 `_pending_*`，`configure()` 时一次性补写进宿主 —— 于是
# "先 new 后设属性、最后绑定"（老代码的写法）与"先绑定后设属性"两种顺序结果一致。
# 【转发不回写暂存】host 已绑定时 setter 直接写宿主，**不再**记暂存值：残留的旧暂存会在
# 下一次 configure() 里把宿主上更新过的值改回去（"陈旧暂存覆盖新值"是一类很难查的时序 bug）。

## 暂存区：host 未绑定时接收转发写入的值（见 _flush_pending_to_host）。
var _pending_data: QVoxelSource = null
## 各暂存项是否被真正设过：只有设过的才在 configure() 时补写宿主，
## 避免"默认值覆盖宿主 Inspector 里的显式配置"。
var _pending_set: Dictionary = {}


## 把暂存值补写进宿主（只在 host 未绑定时攒下的项）。
func _flush_pending_to_host() -> void:
	if host == null or _pending_set.is_empty():
		return
	if _pending_set.has(&"data"):
		host.data = _pending_data
	if _pending_set.has(&"voxel_scale"):
		host.voxel_scale = _pending_voxel_scale
	if _pending_set.has(&"generate_collision"):
		host.generate_collision = _pending_generate_collision
	if _pending_set.has(&"lod_count"):
		host.lod_count = _pending_lod_count
	if _pending_set.has(&"view_distance"):
		host.view_distance = _pending_view_distance
	if _pending_set.has(&"visibility_mode"):
		host.visibility_mode = _pending_visibility_mode
	_pending_set.clear()
	_pending_data = null


# 暂存字段（仅 host 未绑定时有意义）
var _pending_voxel_scale: float = 0.1
var _pending_generate_collision: bool = false
var _pending_lod_count: int = 1
var _pending_view_distance: float = 40.0
var _pending_visibility_mode: VoxelRenderer.VisibilityMode = VoxelRenderer.VisibilityMode.FRUSTUM


## 体素数据（转发 host.data）。[兼容转发]
var data: QVoxelSource:
	get:
		return host.data if host != null else _pending_data
	set(v):
		if host != null:
			host.data = v
		else:
			_pending_data = v
			_pending_set[&"data"] = true


## 体素边长（转发 host.voxel_scale）。[兼容转发]
var voxel_scale: float:
	get:
		return host.voxel_scale if host != null else _pending_voxel_scale
	set(v):
		if host != null:
			host.voxel_scale = v
		else:
			_pending_voxel_scale = v
			_pending_set[&"voxel_scale"] = true


## 是否生成碰撞（转发 host.generate_collision）。[兼容转发]
var generate_collision: bool:
	get:
		return host.generate_collision if host != null else _pending_generate_collision
	set(v):
		if host != null:
			host.generate_collision = v
		else:
			_pending_generate_collision = v
			_pending_set[&"generate_collision"] = true


## LOD 层数（转发 host.lod_count）。[兼容转发]
var lod_count: int:
	get:
		return host.lod_count if host != null else _pending_lod_count
	set(v):
		if host != null:
			host.lod_count = v
		else:
			_pending_lod_count = v
			_pending_set[&"lod_count"] = true


## 可见性加载距离（转发 host.view_distance）。[兼容转发]
var view_distance: float:
	get:
		return host.view_distance if host != null else _pending_view_distance
	set(v):
		if host != null:
			host.view_distance = v
		else:
			_pending_view_distance = v
			_pending_set[&"view_distance"] = true


## 可见性模式（转发 host.visibility_mode）。[兼容转发]
var visibility_mode: VoxelRenderer.VisibilityMode:
	get:
		return host.visibility_mode if host != null else _pending_visibility_mode
	set(v):
		if host != null:
			host.visibility_mode = v
		else:
			_pending_visibility_mode = v
			_pending_set[&"visibility_mode"] = true


## 诊断开关（转发 host.diag_enabled）。[兼容转发]
## 【为什么这个也转发】诊断输出是本组件写的，但开关的真值只有一个 —— 宿主的 Inspector。
## 保留可写是为了让"只打开破坏侧诊断"的老写法继续可用。
var diag_enabled: bool:
	get:
		return host.diag_enabled if host != null else false
	set(v):
		if host != null:
			host.diag_enabled = v


## 无限层（只读转发 host.infinite_layer）。[兼容转发]
## 早期调用方会用 `d.infinite_layer` 做视锥判定 / 读 origin_chunk；组件化后该能力在宿主上。
var infinite_layer: VoxelInfiniteLayer:
	get:
		return host.infinite_layer if host != null else null


## 表面材质表（只读转发 host.surface_materials()）。[兼容转发]
## 破坏侧曾直接用它取"内核唯一材质缓存"；现在掉落实体走表现层，但外部兼容保留。
func surface_materials() -> Array:
	return host.surface_materials() if host != null else []


## 硬化反馈缓冲：pos -> remaining，_process 帧尾合并发 voxel_hardened_batch
var _hardened_buffer: Dictionary = {}
var _hardened_dirty: bool = false

## 编辑内核：伤害结算 / 应力传播 / 失稳检测的**纯编辑数学**。
## 无节点、无 _process、可无头调用 —— 服务端 / 建模"画笔" / 批处理工具不需要本节点，
## 直接 `VoxelEditKernel.new()` 即可复用同一套数学。
## 本节点只负责：Inspector 旋钮（@export，RefCounted 挂不了）、在途队列分帧调度、
## 表现层（粒子 / 掉落刚体 / 信号 / 帧尾合并 / 诊断输出）。
var _edit := VoxelEditKernel.new()

## 破坏表现层：粒子碎片 / 掉落物理由它演出，宿主只产出数据并委托。
## 【为何惰性创建】与宿主的 infinite_layer 同因：脚本热重载不会对既有实例重跑 _init，
## 用 getter 可自愈，避免"重载后旧实例的 _presenter_impl 仍为 null"这类只在编辑器里冒出来的空引用。
## 【为何 configure 在 _process 里同步】碎片手感旋钮是本节点的 @export（Inspector 唯一真值），
## 而碎片生成全部发生在 _process 的破坏管道内——每帧同步一次即可覆盖全部生成路径，
## 且 Inspector 改旋钮下一帧就生效（与原"调用时读字段"的语义等价）。
## 【注意展示层的 host 是渲染器】它要读 voxel_scale / data / infinite_layer / surface_materials()，
## 故构造时传的是 `host`（渲染器）而非 `self`（本组件）。host 尚未绑定时传 null 也安全：
## 表现层的所有方法都对 `host == null` 做了空转保护（且真正生成碎片只在运行期、host 已绑定时）。
## 绑定顺序不限：getter 在每次取用时把 `host` 与表现层对齐（见 _sync_presenter_host）。
var _presenter_impl: VoxelDestructionPresenter

var _presenter: VoxelDestructionPresenter:
	get:
		if _presenter_impl == null:
			_presenter_impl = VoxelDestructionPresenter.new(host)
			_presenter_impl.name = "_VoxelDestructionPresenter"
			add_child(_presenter_impl, false, Node.INTERNAL_MODE_BACK)
		elif _presenter_impl.host != host:
			# 宿主在表现层创建之后才绑定（先 new 表现层再 configure）→ 就地补上，不必重建节点
			_presenter_impl.host = host
		return _presenter_impl

## 崩塌掉落模式枚举
enum CollapseMode {
	COLLAPSE_NONE,   ## 不启用悬空崩塌
	COLLAPSE_DEBRIS, ## 悬空体素转成粒子碎片掉落
}

## 破坏时是否生成碎片
@export var spawn_debris_on_damage: bool = true:
	set(v):
		spawn_debris_on_damage = v
		# 影响 debris 系列属性有效性 → 刷新 Inspector 隐藏/显示
		notify_property_list_changed()


## Inspector 动态可见性：条件不生效时隐藏对应属性。
## 【为何没有 super 调用】改造前这里转发给 VoxelRenderer 的 `_validate_property`（它隐藏
## view_distance / lod_count 等视点属性）。组件化后那些属性归宿主，本组件面板里根本不存在，
## 没有需要转发的目标；Node3D 也没有同名实现可调。
func _validate_property(property: Dictionary) -> void:
	var name: StringName = property["name"]
	if not spawn_debris_on_damage:
		match name:
			&"max_debris_per_hit", &"debris_speed_range", &"debris_lifetime", &"debris_gravity_scale":
				# 碎片关闭时碎片数量/速度/寿命/重力参数无效
				property["usage"] = int(property["usage"]) & ~PROPERTY_USAGE_EDITOR

## 单次破坏生成的最大碎片数量 (性能保护)
@export var max_debris_per_hit: int = 16

## 崩塌掉落模式
@export var collapse_mode: CollapseMode = CollapseMode.COLLAPSE_DEBRIS

## 局部增量崩塌检测：只检查破坏位置 6 邻附近可能失稳的体素
## 开启后破坏调用传入破坏位置，大幅减少每次崩塌检测的 BFS 范围（适合中频破坏+中型场景）
## 关闭则每次全量遍历所有体素判定（结果最精确，适合小型场景/低频）
@export var local_collapse: bool = true

## 逐体素健康度系统开关：关闭时忽略材质硬度，一击即碎
@export var use_voxel_health: bool = true

## 单次破坏对每个体素造成的伤害 (逐体素健康度用)
## 结合材质 hardness，伤害累积达到 hardness 才真正移除体素
@export var damage_per_voxel: float = 1.0

## 碎片粒子初始速度范围（Vector2 = [最小, 最大]，基准值，受材质 mass 影响）
## 最终速度 = 基准速度 / sqrt(mass) ，重物飞得近，轻物飞得远
@export var debris_speed_range: Vector2 = Vector2(2.0, 6.0)

## 碎片粒子生命周期 (秒)（基准值，受材质 mass 影响）
## 最终生命周期 = 基准生命周期 * (1.0 + 0.5 / mass) ，重物落地快消失快
@export var debris_lifetime: float = 3.0

## 碎片粒子重力倍数（基准值，受材质 mass 影响）
## 最终重力 = 基准重力 * mass ，重物受重力影响更大
@export var debris_gravity_scale: float = 1.0

## 整体健康度 (<=0 时触发完全破坏，-1 表示不启用健康度系统)
@export var health: float = -1.0

## 应力传播（裂纹扩散）距离（步数），即裂纹最多扩散多少层
## 破坏体素时，应力向邻居传播，当应力超过材质的 connection_strength 时，邻居也会断裂
## 产生更真实的渐进裂纹扩散效果
@export_range(1, 10) var stress_max_steps: int = 3

## 每次破坏产生的应力大小（与材质 connection_strength 比较决定是否断裂）
@export var stress_force: float = 15.0

## 应力衰减系数（每传播一步应力的衰减比例）
@export_range(0.0, 1.0) var stress_decay: float = 0.5

## 监控统计
var last_damage_count: int = 0     ## 最近一次破坏实际移除的体素数
var last_collapse_count: int = 0   ## 最近一次崩塌的悬空体素数

## 逐体素累计伤害账**不在这里**：它归 QVoxelSource（体素相邻状态，必须与 chunk 缓冲同生共死——
## 卸载 / 清空 / origin shift / 载荷重建都要同步清理）。放在本节点上时无人负责清理，
## 残留伤害会"继承"给后来放上去的新体素（一放上去就被秒杀），且随卸载无限增长。
## 本节点只负责"发起伤害"，伤害账读写由编辑内核经 data 的内部协议完成（见 VoxelEditKernel）。

## 破坏形状常量（对应原生 damage_shape 的 shape 参数）
const SHAPE_SPHERE: int = 0
const SHAPE_BOX: int = 1

## 延迟移除状态：同一帧内多次伤害的位置合并去重，下一帧统一处理
## key: Vector3i 体素位置，value: 是否生成碎片（任意一次伤害要求生成则生成）
var _pending_removed: Dictionary = {}  # key: Vector3i(pos), value: bool(spawn_debris)
var _pending_spawn_debris: bool = false

## 粒子对象池 / 淡出渐变 / 碎片根节点 / 掉落物理（对象池、在途队列、生命周期账本）
## 等**表现层状态**已全部迁往 VoxelDestructionPresenter。
## 掉落块材质也由表现层经 `host.surface_materials()` 取内核唯一材质缓存，与渲染共用同一份对象。

## 级联崩塌状态：逐帧处理，每帧只处理一个级联层级
## 存放当前层级的待检查体素位置，处理完后自动设置为下一级的位置
## 为空时表示没有待处理的级联
var _cascade_check_positions: Array = []  # 待检查的体素位置（下一级联层级）
var _cascade_total: Array = []            # 所有级联累积的失稳体素

## 级联分帧化：大面积崩塌（数万体素）时，单帧处理全部体素会造成主线程
## 数百毫秒卡顿（检测+分组+材质+移除+生成 全同步）。按体素数量切块，
## 每帧只处理 MAX_CASCADE_VOXELS_PER_FRAME 个，剩余存入待处理队列，
## 把 1174ms 级联阻塞摊平到多帧（检测每帧重跑，天然支持传播链继续）。
## 注意：分块检测的代价是每次 _find_unstable_voxels 都基于当前数据状态，
## 分批处理保证正确性（移除前体素已判定失稳），只是时序上分多帧。
const MAX_CASCADE_VOXELS_PER_FRAME: int = 4096
## 分帧处理剩余待移除体素（尚未分组/移除的失稳体素）
var _cascade_pending_voxels: Array = []

## 掉落物生成模式（统一"小块粒子/大块物理体"的分档策略）
enum FallingMode {
	AUTO,     ## 自动按体素数分档：小碎块转粒子，中块 Box 碰撞，大块凸包碰撞（推荐）
	PARTICLE, ## 全部转 GPU 粒子（零物理开销，视觉最轻量）
	PHYSICS,  ## 全部物理体（Box/凸包碰撞，保留整块碎裂的物理感）
}

## 掉落物生成模式（见 FallingMode）
@export var falling_mode: FallingMode = FallingMode.AUTO

## 物理掉落体对象池大小：同时最多存在的活动 RigidBody3D 数量。
## 池复用消除创建/销毁开销，同时作为物理体数量的软上限（池满的新块转粒子，优雅降级）。
## 设大些避免大崩塌时过早降级（大块转粒子会损失"整块碎裂"的物理感）。
@export_range(8, 512) var falling_chunk_pool_size: int = 64

## 掉落块最大存活数量（超出后最早冻结的块被移除，防止长时间破坏后物理体无限堆积拖慢帧率）
@export_range(20, 2000) var max_falling_chunks: int = 200

## 掉落块冻结后的最长保留时间（秒），到期后自动移除（已经落地静止，视觉任务完成）
@export_range(1.0, 60.0) var falling_chunk_cleanup_time: float = 6.0

## 掉落块落地静置检测时间累计 (秒)
var _sleep_check_counter: float = 0.0

## 就绪：惰性绑定父节点宿主 + 让表现层准备好碎片根节点。
##
## 【为什么在 _ready 里从父节点取宿主】编辑器里把本组件拖到 VoxelRenderer 节点下是零代码的
## 用法，此时没有人会调 `configure()`。父节点不是 VoxelRenderer（例如先用代码挂到普通 Node3D
## 下再 configure）时保留 null，等 `configure()` 显式绑定 —— 不报错，只在破坏调用时空转。
func _ready() -> void:
	if host == null and get_parent() is VoxelRenderer:
		configure(get_parent() as VoxelRenderer)
	if not Engine.is_editor_hint():
		_presenter.ensure_debris_root()
		# 不再做初始全量稳定性校验：浮空结构默认保持稳定，失稳只由破坏逻辑
		# （局部检测）触发，避免打开场景时主线程全量遍历体素（百万级体素可卡数秒）。
		# 需要主动校验时调用方手动调 validate_stability()
		# 支撑检测采用实时局部查询（LOWER_5 邻居统计），无需预热任何缓存——
		# 失稳传播只访问破坏点附近体素（微秒级），零初始化开销。


func _exit_tree() -> void:
	# 直接用 _presenter_impl（不触发惰性创建）：退出期不该再新建节点。
	# 表现层 shutdown() 会先 join 在途 mesh worker 再清理（见 VoxelDestructionPresenter）。
	if _presenter_impl != null:
		_presenter_impl.shutdown()
	# 断开宿主信号：宿主通常比本组件活得久（demo 重置时只换 data 不换宿主），
	# 留着连接会让它的 mesh_updated 打到已释放实例。
	_unbind_host_signals()
	# 【改造前这里是 super._exit_tree()】那部分归渲染器了：等待在途 mesh worker、置 _exiting、
	# 清理 LOD 网格都是宿主自己 `_exit_tree` 的职责，本组件作为子节点退出时宿主仍在，
	# 不需要也不该替它做。


## origin shift 钩子：把本组件持有的**体素坐标**在途队列一起平移。
## 【为什么必须做】宿主只平移渲染层状态（网格节点/碰撞体/block 级账本），而破坏系统的
## 队列里存的是体素坐标。数据坐标整体挪了 shift 后若不平移这些队列，下一帧处理时：
##   · `_pending_removed`      → 在错位位置移除体素（破坏打到别处/静默无效）；
##   · `_cascade_*`            → 级联检测与移除错位；
##   · 表现层的 `_pending_falling_*` → 生成错位的掉落体与材质映射（转发给表现层处理）。
## 长距离旅行（触发 origin shift）时这些队列常非空，属"真跑才暴露"的一类。
##
## 【为什么改由本组件自己发现】改造前宿主（VoxelRenderer）`shift_render` 末尾会回调
## `on_origin_shift` 这个"子类钩子"，本组件于是天然收到通知。组件化后那层继承关系没了，
## 而 VoxelRenderer 是**不可改**的（它已把钩子固定留给子类），故本组件改为在 `_process`
## 里比对宿主的公开面 `infinite_layer.origin_chunk()`：变了就差分出 shift 并自行平移。
## 代价是每帧一次整数比较；收益是零侵入宿主。该值只在 `data.infinite` 的无限世界才会变。
func on_origin_shift(shift: Vector3i) -> void:
	_pending_removed = VoxelChunk.shift_key_dict(_pending_removed, shift)
	_hardened_buffer = VoxelChunk.shift_key_dict(_hardened_buffer, shift)
	_cascade_check_positions = VoxelChunk.shift_positions(_cascade_check_positions, shift)
	_cascade_pending_voxels = VoxelChunk.shift_positions(_cascade_pending_voxels, shift)
	_cascade_total = VoxelChunk.shift_positions(_cascade_total, shift)
	if _presenter_impl != null:
		_presenter_impl.on_origin_shift(shift)


## 上次看到的宿主数据基准 chunk（见 on_origin_shift 的"为什么改由本组件自己发现"）。
var _last_origin_chunk: Vector3i = Vector3i.ZERO


## 轮询宿主的数据基准 chunk，若发生 origin shift 就平移本组件的在途队列。
## 【为什么是轮询而不是信号】VoxelRenderer 没有暴露 origin shift 信号，且它不可改；
## `origin_chunk()` 是无限层的公开查询（HUD/调试本来就读它），用它做差分是既有公开面上的最小方案。
func _sync_origin_shift() -> void:
	if host == null:
		return
	var cur: Vector3i = host.infinite_layer.origin_chunk()
	if cur == _last_origin_chunk:
		return
	var shift := cur - _last_origin_chunk
	_last_origin_chunk = cur
	on_origin_shift(shift)


# 破坏入口

## 球形破坏: 对中心点半径内的体素造成伤害
## center 为体素空间坐标 (1单位 = 1体素)，radius 单位同上
## 仅更新 damage_map（即时），实际移除在下一帧统一处理
## 返回被判定为应移除的体素位置数组（基于累计伤害）
func damage_sphere(center: Vector3, radius: float, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	# 一趟原生内核完成：范围 → 材质 → 硬度比较 → 累伤 / 判移除（伤害结算下沉原生，语义不变）
	var removed := _apply_damage_native(SHAPE_SPHERE, center, radius, Vector3i.ZERO, Vector3i.ZERO)
	# 2. 合并去重：同一帧内多次伤害相同位置只处理一次
	if not removed.is_empty():
		for pos in removed:
			_pending_removed[pos] = true
		_pending_spawn_debris = _pending_spawn_debris or do_spawn
	return removed


## 盒形破坏
## 仅更新 damage_map（即时），实际移除在下一帧统一处理
func damage_box(aabb: AABB, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var mn := Vector3i(floori(aabb.position.x), floori(aabb.position.y), floori(aabb.position.z))
	var mx := Vector3i(floori(aabb.end.x - 1.0), floori(aabb.end.y - 1.0), floori(aabb.end.z - 1.0))
	var removed := _apply_damage_native(SHAPE_BOX, Vector3.ZERO, 0.0, mn, mx)
	if not removed.is_empty():
		for pos in removed:
			_pending_removed[pos] = true
		_pending_spawn_debris = _pending_spawn_debris or do_spawn
	return removed


## 单体素破坏
func damage_voxel(pos: Vector3i, spawn_debris: Variant = null) -> bool:
	if not data or not data.has_voxel(pos):
		return false
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var removed := _apply_damage_native(SHAPE_BOX, Vector3.ZERO, 0.0, pos, pos)
	if not removed.is_empty():
		for p in removed:
			_pending_removed[p] = true
		_pending_spawn_debris = _pending_spawn_debris or do_spawn
	return not removed.is_empty()


## 射线破坏 (DDA)，朝指定方向破坏命中的第一个体素
func damage_ray(origin: Vector3, direction: Vector3, max_distance: float = 100.0, spawn_debris: Variant = null) -> Vector3i:
	if not data:
		return Vector3i.MIN
	var hit := raycast_voxel(origin, direction, max_distance)
	if hit != Vector3i.MIN:
		damage_voxel(hit, spawn_debris)
	return hit


## 射线检测体素（DDA）。委托 [VoxelRay] —— 走格实现全项目只此一份，
## 编辑器的拾取（还要入射面法线）与这里的破坏因此不会各走一套。
## 注：direction 为零向量时返回 MIN（旧实现会沿 -z 一直推进，属退化输入的修复）。
func raycast_voxel(origin: Vector3, direction: Vector3, max_distance: float = 100.0) -> Vector3i:
	return VoxelRay.hit_voxel(data, origin, direction, max_distance)


## 完全破坏: 移除所有体素
func destroy_all(spawn_debris: Variant = null) -> void:
	if not data:
		return
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var positions: Array = data.get_positions()
	var mat_map := _collect_voxel_materials(positions)
	if do_spawn and not Engine.is_editor_hint():
		_presenter.spawn_debris_with_materials(positions, mat_map)
	data.clear()
	voxel_damaged.emit(positions, do_spawn)


## 修复整体健康度
func repair(amount: float) -> void:
	if health >= 0:
		health = max(health + amount, 0.0)


# 逐体素健康度 + 伤害应用

## 即时伤害应用：委托编辑内核做数学，本节点只做"表现层收尾"。
##   · 伤害结算 / 硬度比较 / 累伤 / 判移除 → `_edit.apply_damage()`（无节点、可无头调用）
##   · Inspector 旋钮（damage_per_voxel / use_voxel_health）按参数传入内核，内核不存配置
##   · 硬化反馈（受伤未摧毁）并入帧尾合并缓冲 + 置脏 → 本节点（表现层职责）
## 返回应被移除的体素位置；实际移除仍由 _process 的统一管道处理。
func _apply_damage_native(shape: int, center: Vector3, radius: float, vmin: Vector3i, vmax: Vector3i) -> Array:
	var res := _edit.apply_damage(data, shape, center, radius, vmin, vmax,
		damage_per_voxel, use_voxel_health)
	# 硬化反馈 → 与基线同一套缓冲与帧尾合并信号（表现层）
	var hardened: Dictionary = res["hardened"]
	for pos in hardened:
		_hardened_buffer[pos] = hardened[pos]
	if res["hardened_dirty"]:
		_hardened_dirty = true
	var removed: Array = res["removed"]
	last_damage_count = removed.size()
	return removed


## 破坏后的统一处理：崩塌检测 + 应力传播 + 整体健康度扣减
## 在 _process 延迟处理中调用（每帧一个批次）
## 应力传播是轻量 BFS（邻域检查），直接同步执行，无需异步
func _after_removal(removed: Array) -> void:
	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0
	var _stress_count := 0

	# 应力传播：裂纹扩散（始终启用）
	if not removed.is_empty():
		var stress_removed := _propagate_stress(removed)
		_stress_count = stress_removed.size()
		if not stress_removed.is_empty():
			# 应力传播移除的体素先移除，再触发崩塌
			var stress_mat_map := _collect_voxel_materials(stress_removed)
			var _diag_t1 := Time.get_ticks_usec() if diag_enabled else 0
			data.remove_voxels(stress_removed)
			var _diag_t2 := Time.get_ticks_usec() if diag_enabled else 0
			# 应力传播的断裂体素：连通的转为物理体掉落，散落的用粒子
			var stress_groups := []
			if not Engine.is_editor_hint():
				# 按连通性分组，每组生成一个物理体掉落
				stress_groups = QVoxelSource.partition_connected(stress_removed)
				# 为每组构建材质映射
				var stress_group_materials: Array[Dictionary] = []
				for sgroup in stress_groups:
					var sgroup_mat_map: Dictionary = {}
					for pos in sgroup:
						sgroup_mat_map[pos] = stress_mat_map.get(pos, 0)
					stress_group_materials.append(sgroup_mat_map)
				var _diag_t3 := Time.get_ticks_usec() if diag_enabled else 0
				_presenter.spawn_falling_chunks_from_groups(stress_groups, stress_group_materials)
				if diag_enabled:
					var _t_spawn := (Time.get_ticks_usec() - _diag_t3) / 1000.0
					print("[诊断] 应力传播掉落: %d组, 生成耗时%.2f ms" % [stress_groups.size(), _t_spawn])
			removed.append_array(stress_removed)
			if diag_enabled:
				var _t_remove_stress := (_diag_t2 - _diag_t1) / 1000.0
				print("[诊断] 应力传播: 移除%d体素, 移除耗时%.2f ms, 分组%d" % [stress_removed.size(), _t_remove_stress, stress_groups.size() if not Engine.is_editor_hint() else 0])

	_trigger_collapse(removed)
	if health >= 0:
		health -= float(removed.size()) * 0.5
		if health <= 0:
			destroy_all()

	if diag_enabled:
		var _t_total := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _t_total > 1.0:
			print("[诊断] _after_removal: 总%d体素(应力%d), 总耗时%.2f ms" % [removed.size(), _stress_count, _t_total])


# 应力传播（裂纹扩散）

## 应力传播：从被移除的体素出发，向邻居传播应力，材质 `connection_strength` 不足则断裂。
## 委托编辑内核；应力参数是本节点的 Inspector 旋钮，按参数传入。
## 返回所有因应力传播而断裂的体素位置
func _propagate_stress(removed: Array) -> Array:
	return _edit.propagate_stress(data, removed, stress_max_steps, stress_force, stress_decay)


# 悬空检测 + 崩塌掉落

## 检测并处理悬空体素（与地面/支撑断开的体素），崩塌成粒子碎片
## 局部支撑检测：只检查"破坏位置附近"的悬空，避免每次破坏都全场景 BFS
## around_positions 为本次破坏移除的体素位置；为空则做全场景检测
## 级联崩塌：崩塌掉落的体素也是"被移除"，会再次触发局部检测，连锁反应直到无更多失稳
## 每次调用只处理一个级联层级，剩余工作由 _process 在后续帧继续处理
func _trigger_collapse(around_positions: Array = []) -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return

	# 全场景检测（around_positions 为空）：同步完成所有级联层级
	# 仅在 validate_stability 等初始化场景调用
	if around_positions.is_empty():
		_process_full_cascade()
		return

	# 局部检测：合并到待处理队列（不覆盖已有级联，避免新破坏导致正在进行的级联丢失）
	# 去重：避免同一位置被多次检查
	if _cascade_check_positions.is_empty():
		_cascade_check_positions = around_positions.duplicate()
	else:
		# 已有级联正在处理，合并新位置
		var existing: Dictionary = {}
		for pos in _cascade_check_positions:
			existing[pos] = true
		for pos in around_positions:
			if not existing.has(pos):
				_cascade_check_positions.append(pos)
				existing[pos] = true




## 全场景级联崩塌检测（同步完成所有层级）
## 统一使用整块物理体掉落（FallingChunk），而非粒子碎片
func _process_full_cascade() -> void:
	var check_positions: Array = []
	var total_unstable: Array = []
	var guard := 64
	while guard > 0:
		guard -= 1
		var unstable := _find_unstable_voxels(check_positions)
		if unstable.is_empty():
			break
		total_unstable.append_array(unstable)
		check_positions = unstable
	if total_unstable.is_empty():
		return

	# 按连通性分组，每组生成一个 FallingChunk
	var groups := QVoxelSource.partition_connected(total_unstable)
	# 收集每组体素的材质ID（在移除前）
	var group_materials := _collect_group_materials(groups, total_unstable)
	data.remove_voxels(total_unstable)
	if not Engine.is_editor_hint():
		_presenter.spawn_falling_chunks_from_groups(groups, group_materials)

	voxels_about_to_collapse.emit(total_unstable)
	last_collapse_count = total_unstable.size()
	voxel_damaged.emit(total_unstable, true)


## 处理级联崩塌（分帧处理，大面积崩塌时把主线程阻塞摊平到多帧）
## 从 _cascade_check_positions 出发，单轮找出级联失稳体素并统一移除
## 性能优化（合并级联层级 + 分帧切块）：
##   - 旧实现每帧只处理一个级联层级，BFS 多轮重复扫描（每轮 10-13ms），
##     5 级级联 = 50-65ms 链式阻塞。find_unsupported_around() 内部已用支撑图
##     把连锁失稳"单轮递归传播"到终结，一次调用获得全部失稳体素。
##   - 超大崩塌（数万体素）时单帧全处理仍会主线程卡顿数百 ms（检测+分组+
##     材质+移除+生成全同步）。因此按 MAX_CASCADE_VOXELS_PER_FRAME 切块：
##     每帧只处理一批，剩余体素存 _cascade_pending_voxels，下帧继续检测。
func _process_cascade_level() -> void:
	# 优先处理上帧遗留的待移除体素（已判定失稳，直接走分组/移除/生成）
	# 注意：遗留体素可能仍超单帧上限（上一帧一次性全量放入），需再次分帧
	if not _cascade_pending_voxels.is_empty():
		if _cascade_pending_voxels.size() > MAX_CASCADE_VOXELS_PER_FRAME:
			var batch: Array = _cascade_pending_voxels.slice(0, MAX_CASCADE_VOXELS_PER_FRAME)
			_cascade_pending_voxels = _cascade_pending_voxels.slice(MAX_CASCADE_VOXELS_PER_FRAME)
			_process_cascade_batch(batch)
			if diag_enabled:
				print("[诊断] 级联分帧(遗留): 本帧%d体素, 剩余%d" % [batch.size(), _cascade_pending_voxels.size()])
			return
		var pending: Array = _cascade_pending_voxels
		_cascade_pending_voxels = []
		_process_cascade_batch(pending)
		return

	if _cascade_check_positions.is_empty():
		return

	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0

	# 取出当前待检查位置，清空队列（处理完即终结本次级联）
	var queue: Array = _cascade_check_positions
	_cascade_check_positions = []

	var unstable := _find_unstable_voxels(queue)
	if diag_enabled:
		print("[诊断] 级联检测: queue=%d, 检测出unstable=%d" % [queue.size(), unstable.size()])
	if unstable.is_empty():
		_finalize_cascade()
		return

	# 超大崩塌分帧：超过单帧上限时只处理前 MAX_CASCADE_VOXELS_PER_FRAME 个，
	# 剩余存入待处理队列，由 _process 下一帧继续（避免单帧 1 秒级主线程卡顿）
	if unstable.size() > MAX_CASCADE_VOXELS_PER_FRAME:
		var batch: Array = unstable.slice(0, MAX_CASCADE_VOXELS_PER_FRAME)
		_cascade_pending_voxels = unstable.slice(MAX_CASCADE_VOXELS_PER_FRAME)
		_process_cascade_batch(batch)
		if diag_enabled:
			print("[诊断] 级联分帧: 本帧%d体素, 剩余%d" % [batch.size(), _cascade_pending_voxels.size()])
		return

	_process_cascade_batch(unstable)


## 处理一批失稳体素：分组 → 收集材质 → 移除 → 生成掉落体
## 供 _process_cascade_level 单帧批处理与分帧待处理队列共用
func _process_cascade_batch(unstable: Array) -> void:
	if unstable.is_empty():
		return
	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0

	# 按连通性分组
	var groups := QVoxelSource.partition_connected(unstable)
	var _diag_t2 := Time.get_ticks_usec() if diag_enabled else 0

	# 收集材质快照（在移除前）
	var group_materials := _collect_group_materials(groups, unstable)
	var _diag_t3 := Time.get_ticks_usec() if diag_enabled else 0

	# 移除失稳体素
	data.remove_voxels(unstable)
	var _diag_t4 := Time.get_ticks_usec() if diag_enabled else 0

	# 生成物理体（每帧限制数量，使用统一入口）
	if not Engine.is_editor_hint():
		_presenter.spawn_falling_chunks_from_groups(groups, group_materials)
	var _diag_t5 := Time.get_ticks_usec() if diag_enabled else 0

	# 累积级联结果
	_cascade_total.append_array(unstable)

	# 本批处理完且无遗留 → 终结。
	# 单轮级联：find_unsupported_around 内部已沿支撑链传播完整级联，
	# 无需把 unstable 再次作为 removed 继续检测（否则配合较宽松的支撑判定
	# 会连锁放大 → 破坏一点整楼/整行塌）。
	if _cascade_pending_voxels.is_empty():
		_finalize_cascade()

	if diag_enabled:
		var _t_total := (_diag_t5 - _diag_t0) / 1000.0
		var _t_group := (_diag_t2 - _diag_t0) / 1000.0
		var _t_mat := (_diag_t3 - _diag_t2) / 1000.0
		var _t_remove := (_diag_t4 - _diag_t3) / 1000.0
		var _t_spawn := (_diag_t5 - _diag_t4) / 1000.0
		if _t_total > 1.0:
			print("[诊断] 级联批处理: %d体素, %d组, 总%.2fms | 分组%.2f | 材质%.2f | 移除%.2f | 生成%.2f" % [unstable.size(), groups.size(), _t_total, _t_group, _t_mat, _t_remove, _t_spawn])


## 完成级联、发信号
func _finalize_cascade() -> void:
	if _cascade_total.is_empty():
		return
	voxels_about_to_collapse.emit(_cascade_total)
	last_collapse_count = _cascade_total.size()
	voxel_damaged.emit(_cascade_total, true)
	_cascade_total = []
	_cascade_check_positions = []



## 找出所有"失稳"体素，返回这些体素位置的并集
## 连通性支撑判断：从贴地(y==0)体素 6 方向 BFS 标记所有"与地面连通"的体素，
## 与地面断开（完全悬空）的体素才会脱落
## around_positions 为本次破坏移除的体素位置：
##   - 局部增量(local_collapse=true)：只检查破坏位置 6 邻附近可能失稳的体素，
##     避免每次破坏都全量 BFS，适合中频破坏 + 中型场景
##   - 全量检测(local_collapse=false)：全局遍历，结果最精确，适合小型场景/低频
## around_positions 为空时回退全量检测
func _find_unstable_voxels(around_positions: Array = []) -> Array:
	var use_local: bool = local_collapse and not around_positions.is_empty()
	var unstable := _edit.find_unstable(data, local_collapse, around_positions)
	if diag_enabled:
		print("[诊断] _find_unstable_voxels: around=%d, 局部=%s, 结果=%d" % [around_positions.size(), use_local, unstable.size()])
	return unstable


## 全量校验当前场景的悬空体素并触发崩塌（局部检测的初始化）
## 局部检测只关注破坏点附近，无法发现"初始就悬空"的结构（如浮岛装饰）
## 在加载关卡/读取存档后调用一次，确保场景进入静态稳定状态
## 之后破坏导致的失稳由局部检测负责
## 统一使用整块物理体掉落（FallingChunk），而非粒子碎片
func validate_stability() -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return
	var unstable := _find_unstable_voxels([])  # 空 around → 全量检测
	if unstable.is_empty():
		return
	# 按连通性分组，每组生成一个 FallingChunk
	var groups := QVoxelSource.partition_connected(unstable)
	# 收集每组体素的材质ID（在移除前）
	var group_materials := _collect_group_materials(groups, unstable)
	data.remove_voxels(unstable)
	if not Engine.is_editor_hint():
		_presenter.spawn_falling_chunks_from_groups(groups, group_materials)
	voxels_about_to_collapse.emit(unstable)
	voxel_damaged.emit(unstable, true)
	last_collapse_count = unstable.size()




func _collect_voxel_materials(positions: Array) -> Dictionary:
	# 原生批量收集（chunk 缓冲直读，替代逐体素 get_voxel 字典查询）；原生库为强制依赖。
	return NativeLoader.collect_materials(data._chunk_buffers_view() if data else {}, positions)


## 按连通分组逐组建立 pos→材质ID 映射（移除前调用，供掉落体使用）。
## 一趟原生批量读取全部位置（chunk 缓冲直读），再按组分片——替代原"逐组逐体素
## data.get_voxel()"字典查询（大崩塌时数万次哈希查找全在主线程）。
## 空/未知位置返回 -1，与 data.get_voxel 的既有语义一致。
func _collect_group_materials(groups: Array, positions: Array) -> Array[Dictionary]:
	var all_mats := _collect_voxel_materials(positions)
	var out: Array[Dictionary] = []
	for group in groups:
		var mat_map: Dictionary = {}
		for pos in group:
			mat_map[pos] = all_mats.get(pos, -1)
		out.append(mat_map)
	return out


# 主循环

## 帧尾合并发射硬化反馈信号：一次破坏几百个体素未摧毁时，
## 避免逐体素 emit voxel_hardened（几百次信号/破坏 → 高频轰炸外部监听器），
## 累积后统一发一次 voxel_hardened_batch（兼发兼容性单发信号到已连接监听器）。
func _flush_hardened_signals() -> void:
	if not _hardened_dirty:
		return
	_hardened_dirty = false
	var positions: Array = _hardened_buffer.keys()
	if positions.is_empty():
		return
	voxel_hardened_batch.emit(positions, _hardened_buffer)
	_hardened_buffer.clear()


func _process(_delta: float) -> void:
	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0
	# 【改造前这里是 super._process(_delta)】渲染每帧驱动归宿主：它就是本组件的**父节点**，
	# Godot 按场景树顺序处理 `_process`（父先于子），故宿主本帧的网格重建一定已经跑完，
	# 破坏管道看到的渲染状态与改造前"父类先跑"完全等价，无需在此重复调用。
	# 【STATIC 宿主】若无人在宿主上设 DYNAMIC，configure() 已发过警告，这里不重复拦。
	if Engine.is_editor_hint():
		return

	# 宿主发生 origin shift（无限世界走远）时，本组件的体素坐标队列必须同步平移（见 on_origin_shift）。
	_sync_origin_shift()

	# 把碎片手感 / 掉落旋钮同步给表现层（@export 是本节点唯一真值；
	# 碎片与掉落生成都在本帧管道内，故每帧推一次即可覆盖运行期改值）
	_presenter.configure(max_debris_per_hit, debris_speed_range, debris_lifetime, debris_gravity_scale,
			falling_mode, falling_chunk_pool_size, max_falling_chunks, falling_chunk_cleanup_time)

	# 处理级联崩塌（分帧：单帧处理一批，大面积崩塌摊平到多帧避免主线程卡顿）
	if not _cascade_check_positions.is_empty() or not _cascade_pending_voxels.is_empty():
		var _t1 := Time.get_ticks_usec() if diag_enabled else 0
		_process_cascade_level()
		if diag_enabled:
			var _dt := (Time.get_ticks_usec() - _t1) / 1000.0
			if _dt > 1.0:
				print("[诊断] _process_cascade_level 耗时: %.2f ms, 队列大小: %d" % [_dt, _cascade_check_positions.size()])

	# 处理普通破坏批次（每帧一个）
	_process_destruction_pipeline()

	# 帧尾：从待生成队列限量生成掉落体（摊平大面积崩塌的 GPU/物理负载）
	_presenter.process_pending_falling_groups()
	# 帧尾：GPU 忙时积压的掉落体 mesh 限量组装（add_surface_from_arrays 同步 GPU 上传）
	_presenter.process_pending_mesh_results()

	# 帧尾：合并发射硬化反馈（一次破坏几百个体素未摧毁时，避免逐体素高频信号）
	_flush_hardened_signals()

	# 定期检测掉落块：按时间间隔（约 1 秒）冻结静止块 + 生命周期清理（上限/超时）。
	# 用累计时间而非固定帧数，避免帧率下降时清理频率同步下降的恶性循环。
	_sleep_check_counter += _delta
	if _sleep_check_counter >= 1.0:
		_sleep_check_counter = 0.0
		_presenter.freeze_sleeping_chunks()

	if diag_enabled:
		var _total_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _total_ms > 3.0:
			print("[诊断] VoxelDestructible._process 总耗时: %.2f ms" % _total_ms)


## 延迟破坏管道：每帧处理所有累积的待移除体素（去重合并后）
## 同一帧内多次伤害相同位置合并去重，仅执行一次移除 + 崩塌检测 + 碎片生成
func _process_destruction_pipeline() -> void:
	if _pending_removed.is_empty():
		return

	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0

	# 提取所有待移除位置（去重后的唯一键）
	var removed: Array = _pending_removed.keys()
	var do_spawn: bool = _pending_spawn_debris
	_pending_removed.clear()
	_pending_spawn_debris = false

	if removed.is_empty():
		return

	# 0. 先在移除前收集材质快照（避免移除后 data.voxels 中找不到）
	var mat_map := _collect_voxel_materials(removed) if do_spawn and not Engine.is_editor_hint() else {}
	var _diag_t1 := Time.get_ticks_usec() if diag_enabled else 0

	# 1. 实际移除体素（触发 mesh 脏标记 → 下一帧 _process 自动重建）
	data.remove_voxels(removed)
	var _diag_t2 := Time.get_ticks_usec() if diag_enabled else 0

	# 2. 应力传播 + 崩塌检测 + 处理（同步，轻量 BFS）
	_after_removal(removed)
	var _diag_t3 := Time.get_ticks_usec() if diag_enabled else 0

	# 3. 生成粒子碎片（使用第 0 步收集的材质快照）
	if do_spawn and not Engine.is_editor_hint() and not mat_map.is_empty():
		_presenter.spawn_debris_with_materials(removed, mat_map)
	var _diag_t4 := Time.get_ticks_usec() if diag_enabled else 0

	# 4. 信号
	voxel_damaged.emit(removed, do_spawn)

	if diag_enabled:
		var _t_total := (_diag_t4 - _diag_t0) / 1000.0
		var _t_collect := (_diag_t1 - _diag_t0) / 1000.0
		var _t_remove := (_diag_t2 - _diag_t1) / 1000.0
		var _t_after := (_diag_t3 - _diag_t2) / 1000.0
		var _t_debris := (_diag_t4 - _diag_t3) / 1000.0
		if _t_total > 1.0:
			print("[诊断] 破坏管道: 共%d体素, 总%.2fms | 收集材质%.2f | 移除%.2f | 应力/崩塌%.2f | 粒子%.2f" % [removed.size(), _t_total, _t_collect, _t_remove, _t_after, _t_debris])
