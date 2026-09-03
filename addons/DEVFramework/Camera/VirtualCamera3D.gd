@tool
## 虚拟机位: 只描述"想要的取景姿态与镜头参数", 自身不渲染画面。
##
## 场景里放任意多个机位 + 一个 [CameraBrain3D](真实相机), Brain 每帧选出优先级最高的
## 激活机位并平滑混合过去。分工参考 Unity Cinemachine 的 vcam / Brain 拆分:
## [br]- [member active] + [member priority] 决定谁生效(同优先级取最后激活者, 天然支持"临时机位入栈/出栈")
## [br]- blend_* 描述"切到本机位"的过渡, 每个机位可单独配置; 留空(-1)则用 Brain 默认时长
## [br]- [member target] + [member behaviors] 让机位自己跟随/瞄准目标, Brain 只负责混合。
##   行为是资源(见 [CameraBehaviorDef]), 不挂行为就是固定取景 —— 这也是最常用的形态
## [br]- [member lens_fov] 可覆盖 Brain 的视场角, 混合期间一并插值
## [br]- noise_* 提供常驻"手持感"抖动, 作为机位姿态的一部分参与混合(不写回节点)
##
## 用法:
## [codeblock]
## vcam.set_active(true)      # 场景信号可直接连到 set_active(bind true/false)
## vcam.activate(0.5)         # 代码切换, 并指定本次过渡时长
## vcam.deactivate()          # 退出竞争, 自动回落到上一个激活机位
## CameraTool.get_current()   # 当前生效机位
## [/codeblock]
class_name VirtualCamera3D extends Node3D

## 未生效时的更新策略(对齐 Cinemachine 的 Standby Update: 省 CPU, 但冷机位可能带着旧姿态上台)
enum StandbyUpdate {
	ALWAYS,       ## 每帧都更新: 上台即就位, 机位多时有开销
	ROUND_ROBIN,  ## 未生效的机位轮流更新(默认): 兼顾开销与冷启动
	NEVER,        ## 只有生效时才更新: 最省, 上台瞬间会先对齐一次姿态
}

## 是否参与竞争(参与不等于生效, 还要比优先级)
signal active_changed(value: bool)
## 是否成为当前生效机位(由 Brain 在切换瞬间触发)
signal current_changed(value: bool)

## 所有参与竞争的机位, 按激活先后排列(后激活者在后)
static var active_cameras: Array[VirtualCamera3D] = []
## 缓存的生效机位, 由 _mark_dirty() 置脏后重算(避免 Brain 每帧遍历)
static var _current: VirtualCamera3D = null
static var _current_dirty: bool = true

## 当前生效机位: 优先级最高者; 同优先级取最后激活者; 无可用机位时为 null
static var current: VirtualCamera3D:
	get():
		if _current_dirty:
			_recompute()
		return _current

## 是否参与竞争
@export var active: bool = false:
	set(value):
		if active == value:
			return
		active = value
		if active:
			if not active_cameras.has(self):
				active_cameras.append(self)
		else:
			active_cameras.erase(self)
		active_changed.emit(active)
		_mark_dirty()
		_notify_brain()
		_refresh_process()
		update_gizmos()

## 优先级: 越大越优先; 相同优先级时最后激活者生效
@export var priority: int = 0:
	set(value):
		if priority == value:
			return
		priority = value
		if active:
			_mark_dirty()
			_notify_brain()

## 是否为当前生效机位(只读, 由 Brain 维护)
var is_current: bool = false

@export_group("过渡", "blend_")
## 切到本机位的过渡时长(秒); 小于 0 表示使用 Brain 的默认时长
@export_range(-1, 5, 0.05, "or_greater") var blend_time: float = -1.0
## 过渡曲线类型
@export var blend_trans: Tween.TransitionType = Tween.TRANS_CUBIC
## 过渡缓动方式
@export var blend_ease: Tween.EaseType = Tween.EASE_IN_OUT
## 位置混合轨迹(枚举归属 [CameraTool], 见 [enum CameraTool.BlendStyle]);
## SPHERICAL / CYLINDRICAL 需要枢纽点(机位行为的瞄准点, 或 Brain 的 blend_pivot), 取不到时退化为 LINEAR
@export var blend_style: CameraTool.BlendStyle = CameraTool.BlendStyle.SPHERICAL

@export_group("镜头", "lens_")
## 大于 0 时覆盖 Brain 的视场角(fov), 混合期间一并插值; 0 表示沿用 Brain 自身设置
@export_range(0, 179, 0.5) var lens_fov: float = 0.0

@export_group("目标与行为")
## 行为的目标节点(直接拖节点即可)。固定取景的机位留空, 也无需挂行为
@export var target: Node3D:
	set(value):
		target = value
		_refresh_process()
## 决定机位如何根据 [member target] 计算姿态; 按顺序依次执行。
## 留空 = 机位固定不动(绝大多数机位的用法)。框架内置 [FollowBehaviorDef]、[LookAtBehaviorDef]
## 与 [NoiseBehaviorDef], 也可继承 [CameraBehaviorDef] 自定义。资源形式, 可跨机位复用
@export var behaviors: Array[CameraBehaviorDef]:
	set(value):
		behaviors = value
		_refresh_process()

@export_group("性能")
## 未生效时的更新策略, 见 [enum StandbyUpdate]
@export var standby_update: StandbyUpdate = StandbyUpdate.ROUND_ROBIN:
	set(value):
		standby_update = value
		_refresh_process()

@export_group("编辑器")
## 把本机位对齐到当前编辑器视角: 在 3D 视图里调好取景后一键写入机位
@export_tool_button("对齐到编辑器视角", "Camera3D") var _align_button: Callable = _align_to_editor_view

## activate() 传入的一次性过渡时长, 被 Brain 取用后失效
var _blend_override: float = -1.0
## 由 CameraTool 轮转指定的"本帧可以更新"标记(ROUND_ROBIN 策略)
var _round_robin: bool = false
## 行为共用的累积时间, 见 get_behavior_time()
var _behavior_time: float = 0.0


func _ready() -> void:
	if active and not active_cameras.has(self):
		active_cameras.append(self)
		_mark_dirty()
	_refresh_process()
	_notify_brain()


func _exit_tree() -> void:
	active_cameras.erase(self)
	_mark_dirty()
	_notify_brain()


func _process(delta: float) -> void:
	_update_pose(delta)


# ── 对外 API ──

## 供场景信号直接绑定(如面板 on_opened → set_active(true))
func set_active(value: bool) -> void:
	active = value


## 激活本机位; blend_override >= 0 时覆盖本次过渡时长。
## 已激活时会重新排到末尾, 从而在同优先级下取胜。
func activate(blend_override: float = -1.0) -> void:
	_blend_override = blend_override
	if not active:
		active = true
		return
	active_cameras.erase(self)
	active_cameras.append(self)
	_mark_dirty()
	_notify_brain()


## 退出竞争, Brain 自动混合回上一个仍激活的机位
func deactivate() -> void:
	active = false


## 代码侧添加行为。
## 推荐用本方法而不是直接给 [member behaviors] 赋值: 本版本的 GDScript 会把数组字面量
## 推断为无类型 Array, 赋值给类型化数组属性会报 "Invalid assignment" 而失败。
func add_behavior(behavior: CameraBehaviorDef) -> void:
	if behavior == null or behaviors.has(behavior):
		return
	behaviors.append(behavior)
	_refresh_process()


## 移除一个行为
func remove_behavior(behavior: CameraBehaviorDef) -> void:
	if not behaviors.has(behavior):
		return
	behaviors.erase(behavior)
	_refresh_process()


## 移除全部行为, 机位回到固定取景
func clear_behaviors() -> void:
	if behaviors.is_empty():
		return
	behaviors.clear()
	_refresh_process()


## 取本次过渡时长(< 0 表示交由 Brain 决定); 一次性覆盖值读取后失效。由 Brain 调用。
func consume_blend_time() -> float:
	var time := _blend_override if _blend_override >= 0.0 else blend_time
	_blend_override = -1.0
	return time


## 本机位的最终姿态: 基础姿态 + 各行为的叠加偏移(如手持抖动)。
## 偏移不写回节点, 因此不污染场景、也不反馈给跟随计算。Brain 读取本方法的结果去混合。
func get_pose() -> Transform3D:
	var pose := global_transform.orthonormalized()
	for behavior: CameraBehaviorDef in behaviors:
		if behavior != null:
			pose = behavior.apply_offset(self, pose)
	return pose


## 行为共用的累积时间(秒)。行为是可共享的配置资源, 不存运行时状态,
## 因此按机位累积的相位统一由宿主机位持有。
func get_behavior_time() -> float:
	return _behavior_time


## 立即按当前目标算一次姿态(忽略阻尼), 用于冷机位上台, 避免从旧姿态飘过来
func snap_pose() -> void:
	_update_pose(0.0, true)


# ── 内部 ──

static func _mark_dirty() -> void:
	_current_dirty = true


static func _recompute() -> void:
	_current_dirty = false
	var best: VirtualCamera3D = null
	var stale: Array[VirtualCamera3D] = []
	for cam: VirtualCamera3D in active_cameras:
		if not is_instance_valid(cam) or not cam.is_inside_tree():
			stale.append(cam)
			continue
		if best == null or cam.priority >= best.priority:
			best = cam
	for cam: VirtualCamera3D in stale:
		active_cameras.erase(cam)
	_current = best


## 需要持续更新的场合: 挂了有效行为(Inspector 里新加的空槽位不算)
func _needs_pose_update() -> bool:
	for behavior: CameraBehaviorDef in behaviors:
		if behavior != null:
			return true
	return false


func _refresh_process() -> void:
	set_process(_needs_pose_update() and _should_update_now())


func _should_update_now() -> bool:
	if Engine.is_editor_hint():
		return false
	match standby_update:
		StandbyUpdate.ALWAYS:
			return true
		StandbyUpdate.NEVER:
			return is_current
	return is_current or _round_robin


func _set_round_robin(value: bool) -> void:
	if _round_robin == value:
		return
	_round_robin = value
	_refresh_process()


## 依次执行行为来求解机位姿态(Brain 只读取结果)
func _update_pose(delta: float, instant: bool = false) -> void:
	_behavior_time += delta
	for behavior: CameraBehaviorDef in behaviors:
		if behavior != null:
			behavior.apply(self, delta, instant)


## 球面/柱面混合的枢纽点: 问各个行为谁在瞄准目标; 都不提供则返回 null
func get_aim_point() -> Variant:
	for behavior: CameraBehaviorDef in behaviors:
		if behavior == null:
			continue
		var point: Variant = behavior.get_aim_point(self)
		if point != null:
			return point
	return null


## 由 Brain 调用: 标记生效状态并广播
func _set_current(value: bool) -> void:
	if is_current == value:
		return
	is_current = value
	current_changed.emit(value)
	_refresh_process()
	update_gizmos()


## 通知 Brain 重新挑选机位(下一帧生效)
func _notify_brain() -> void:
	var brain := CameraTool.get_brain()
	if brain != null:
		brain.refresh()


func _align_to_editor_view() -> void:
	if not Engine.is_editor_hint():
		return
	if not Engine.has_singleton(&"EditorInterface"):
		return
	var editor := Engine.get_singleton(&"EditorInterface")
	var view: SubViewport = editor.get_editor_viewport_3d(0)
	var cam: Camera3D = view.get_camera_3d() if view != null else null
	if cam == null:
		return
	global_transform = cam.global_transform
	if lens_fov > 0.0:
		lens_fov = cam.fov
	update_gizmos()
