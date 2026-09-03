@tool
## 相机大脑: 场景中唯一的真实相机, 每帧跟随当前生效的 [VirtualCamera3D], 切换机位时平滑混合。
##
## 机位只负责"取景意图", Brain 负责"怎么过去":
## [br]- 混合按固定时长 + Tween 曲线求权重; 旋转走四元数 slerp, 位置可走直线 / 球面 / 柱面轨迹
## [br]- 混合结束后持续跟随机位: 机位自己移动(或跟随目标)时相机不会掉队
## [br]- 连续快速切换从"当前实际姿态"起混, 不会互相打断跳变
## [br]- 震屏 / 手持抖动 / 鼠标跟随等叠加层走 [member position_offset] / [member rotation_offset]
##   与 [CameraTool.impulse], 与机位混合互不争写 transform
##
## 用法:
## [codeblock]
## CameraTool.get_brain()          # 取当前 Brain
## brain.snap_to_current()         # 传送/场景切换后立即对齐机位
## brain.position_offset = shake   # 常态叠加偏移(TweenShake 可直接写此属性)
## CameraTool.impulse(pos, 1.0)    # 事件性震屏(定向、按距离衰减)
## [/codeblock]
class_name CameraBrain3D extends Camera3D

## 开始混合到新机位(from 可能为 null)
signal blend_started(from: VirtualCamera3D, to: VirtualCamera3D)
## 混合结束(已完全落到该机位)
signal blend_finished(vcam: VirtualCamera3D)

## 当前场景的 Brain(最后进入场景树者)
static var main: CameraBrain3D

## 机位未指定过渡时长时使用的默认时长(秒)
@export_range(0, 5, 0.05, "or_greater") var default_blend_time: float = 1.0
## 非混合期"相机追随机位"的平滑时间(秒), 0 = 严格贴住机位。
## 注意与机位行为里的 damping 区分: 那个是"机位追随目标", 这个是"相机追随机位"
@export_range(0, 2, 0.01, "or_greater") var tracking_damping: float = 0.0
## 混合是否忽略 Engine.time_scale(慢动作/暂停时相机仍按真实时间过渡)
@export var ignore_time_scale: bool = true
## 进入场景时立即对齐当前机位(关闭则从场景中摆放的姿态混合过去)
@export var snap_on_ready: bool = true

@export_group("混合轨迹")
## 球面/柱面混合的枢纽点兜底; 留空时优先用机位行为提供的瞄准点, 两者都没有则退化为直线
@export var blend_pivot: Node3D
## 专属过渡规则(按 from/to 机位名匹配, 留空 = 通配), 命中即覆盖机位自身配置, 见 [CameraBlendDef]
@export var blends: Array[CameraBlendDef] = []

@export_group("叠加偏移")
## 附加位置偏移(相机本地空间): 常态特效写这里, 不会被机位混合覆盖
@export var position_offset: Vector3 = Vector3.ZERO
## 附加旋转偏移(角度, 相机本地空间): 鼠标跟随等写这里
@export var rotation_offset: Vector3 = Vector3.ZERO

## 混合后的基准姿态(不含叠加偏移)
var _pose: Transform3D = Transform3D.IDENTITY
var _pose_fov: float = 75.0
## 基础 fov: 机位不覆盖 fov 时使用(运行期改动 Brain.fov 会被自动同步)
var _base_fov: float = 75.0
## 上一帧写入的 fov, 用于识别外部改动
var _applied_fov: float = 75.0
var _current: VirtualCamera3D = null
var _blend_from: Transform3D = Transform3D.IDENTITY
var _blend_from_fov: float = 75.0
var _blend_pivot: Variant = null
var _blend_style: CameraTool.BlendStyle = CameraTool.BlendStyle.LINEAR
var _blend_time: float = 0.0
var _blend_elapsed: float = 0.0
var _blend_trans: Tween.TransitionType = Tween.TRANS_CUBIC
var _blend_ease: Tween.EaseType = Tween.EASE_IN_OUT
var _dirty: bool = true


func _enter_tree() -> void:
	main = self


func _exit_tree() -> void:
	if main == self:
		main = null


func _ready() -> void:
	_base_fov = fov
	_pose_fov = fov
	_applied_fov = fov
	_pose = global_transform.orthonormalized()
	set_process(not Engine.is_editor_hint())
	if Engine.is_editor_hint():
		return
	# 冲击是静态全局状态, 新场景接管相机时清掉上一个场景的残留, 免得开场就抖
	CameraTool.clear_impulses()
	# 过渡规则按机位名匹配, 手滑写错名字只会静默不命中; 延迟一帧(等场景树就绪)校验一次并警告
	if not blends.is_empty():
		_validate_blend_names.call_deferred()
	if snap_on_ready:
		snap_to_current()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	update_camera(delta)


# ── 对外 API ──

## 每帧驱动: 挑机位 → 混合/跟随 → 叠加偏移 + 冲击写入真实相机
func update_camera(delta: float) -> void:
	CameraTool._advance_round_robin()
	_sync_base_fov()
	if _dirty or VirtualCamera3D.current != _current:
		_solve(false)
	var vcam := _current
	# 没有任何机位时不接管相机, 交回场景自行控制
	if vcam == null or not is_instance_valid(vcam):
		return
	var step := delta / maxf(Engine.time_scale, 0.001) if ignore_time_scale else delta
	var target := vcam.get_pose()
	var target_fov := vcam.lens_fov if vcam.lens_fov > 0.0 else _base_fov
	if _blend_elapsed < _blend_time:
		_blend_elapsed = minf(_blend_elapsed + step, _blend_time)
		var weight: float = Tween.interpolate_value(0.0, 1.0, _blend_elapsed, _blend_time, _blend_trans, _blend_ease)
		_pose = CameraTool.interpolate_transform(_blend_from, target, _blend_pivot, weight, _blend_style)
		_pose_fov = lerpf(_blend_from_fov, target_fov, weight)
		if _blend_elapsed >= _blend_time:
			blend_finished.emit(vcam)
	else:
		var weight := CameraTool.damp_weight(tracking_damping, step)
		_pose = target if weight >= 1.0 else _pose.interpolate_with(target, weight)
		_pose_fov = target_fov if weight >= 1.0 else lerpf(_pose_fov, target_fov, weight)
	_apply()


## 立即对齐当前机位, 无过渡
func snap_to_current() -> void:
	_solve(true)
	var vcam := _current
	if vcam != null and is_instance_valid(vcam):
		_pose = vcam.get_pose()
		_pose_fov = vcam.lens_fov if vcam.lens_fov > 0.0 else _base_fov
	_blend_time = 0.0
	_blend_elapsed = 0.0
	_apply()


## 标记需要重新挑选机位(机位激活/优先级变化时由机位调用), 下一帧生效
func refresh() -> void:
	_dirty = true


## 是否正在混合
func is_blending() -> bool:
	return _blend_elapsed < _blend_time


## 当前生效机位
func get_current_camera() -> VirtualCamera3D:
	return _current


# ── 内部 ──

## 挑出生效机位; 有变化则开一次混合
func _solve(instant: bool) -> void:
	_dirty = false
	var next := VirtualCamera3D.current
	if next == _current:
		# 竞争关系没变: 消化掉可能残留的一次性过渡时长
		if next != null and is_instance_valid(next):
			next.consume_blend_time()
		return
	var prev := _current
	_current = next
	if prev != null and is_instance_valid(prev):
		prev._set_current(false)
	if next == null:
		return
	next._set_current(true)
	# 冷机位先按当前目标对齐一次, 避免从上次离开时的旧姿态飘过来
	next.snap_pose()
	var time := next.consume_blend_time()
	var blend_trans := next.blend_trans
	var blend_ease := next.blend_ease
	var blend_style := next.blend_style
	var rule := _match_blend(prev, next)
	if rule != null:
		# 规则命中即覆盖曲线与轨迹; 时长仅在其明确指定(>= 0)时覆盖
		if rule.time >= 0.0:
			time = rule.time
		blend_trans = rule.trans
		blend_ease = rule.ease
		blend_style = rule.style
	if time < 0.0:
		time = default_blend_time
	# 要求瞬时, 或首次挑到机位且允许直接落位
	if instant or (prev == null and snap_on_ready):
		time = 0.0
	_blend_from = _pose
	_blend_from_fov = _pose_fov
	_blend_pivot = _resolve_pivot(next)
	_blend_style = blend_style
	_blend_time = maxf(time, 0.0)
	_blend_elapsed = 0.0
	_blend_trans = blend_trans
	_blend_ease = blend_ease
	blend_started.emit(prev, next)
	if _blend_time <= 0.0:
		_pose = next.get_pose()
		_pose_fov = next.lens_fov if next.lens_fov > 0.0 else _base_fov
		blend_finished.emit(next)


## 球面/柱面混合的枢纽点: 优先机位行为的瞄准点, 其次 Brain 的 blend_pivot, 都没有则返回 null(退化为直线)。
## 这里不认识任何具体行为类型, 由机位统一代问, 因此自定义行为也能提供枢纽点。
func _resolve_pivot(vcam: VirtualCamera3D) -> Variant:
	var point: Variant = vcam.get_aim_point()
	if point != null:
		return point
	if blend_pivot != null and is_instance_valid(blend_pivot):
		return blend_pivot.global_position
	return null


## 校验 blends 里引用的机位名是否存在于当前场景, 不存在则警告(名字写错只会静默不命中, 很难排查)
func _validate_blend_names() -> void:
	var scene := get_tree().current_scene if get_tree() != null else null
	if scene == null:
		return
	var names := {}
	if scene is VirtualCamera3D:
		names[scene.name] = true
	for node: Node in scene.find_children("*", "VirtualCamera3D", true, false):
		names[node.name] = true
	for rule: CameraBlendDef in blends:
		if rule == null:
			continue
		for key: StringName in [&"from", &"to"]:
			var target: StringName = rule.get(key)
			if target != &"" and not names.has(target):
				LogTool.warn("相机", "过渡规则引用的机位名 [%s] 在场景中不存在(规则 from=%s to=%s); 若机位为运行时动态创建可忽略" % [target, rule.from, rule.to])


## 在 blends 里找出本次切换的最精确规则(见 [method CameraBlendDef.match_score]); 没有则返回 null
func _match_blend(from: VirtualCamera3D, to: VirtualCamera3D) -> CameraBlendDef:
	if blends.is_empty():
		return null
	var from_name: StringName = from.name if from != null and is_instance_valid(from) else &""
	var to_name: StringName = to.name
	var best: CameraBlendDef = null
	var best_score := -1
	for rule: CameraBlendDef in blends:
		if rule == null:
			continue
		var score := rule.match_score(from_name, to_name)
		if score > best_score:
			best_score = score
			best = rule
	return best


## 把基准姿态、叠加偏移与冲击写入真实相机
func _apply() -> void:
	var t := _pose * Transform3D(Basis.from_euler(rotation_offset * (PI / 180.0)), position_offset)
	var impulse: Dictionary = CameraTool.sample_impulse(t.origin)
	var impulse_position: Vector3 = impulse.get("position", Vector3.ZERO)
	var impulse_rotation: Vector3 = impulse.get("rotation", Vector3.ZERO)
	if impulse_position != Vector3.ZERO:
		t.origin += impulse_position
	if impulse_rotation != Vector3.ZERO:
		t.basis = Basis.from_euler(impulse_rotation) * t.basis
	global_transform = t
	fov = _pose_fov
	_applied_fov = _pose_fov


## 运行期外部改了 Brain.fov(而非通过机位覆盖)时, 把新值认作基础 fov
func _sync_base_fov() -> void:
	if absf(fov - _applied_fov) > 0.0001:
		_base_fov = fov
