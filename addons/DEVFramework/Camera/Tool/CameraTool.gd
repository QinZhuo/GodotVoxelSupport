@tool
## 相机模块统一入口(静态): 查询真实相机/生效机位、代码侧切换机位、冲击(震屏)、共享数学。
##
## [codeblock]
## CameraTool.get_camera().global_position          # 真实渲染相机(无 Brain 时退回视口相机)
## CameraTool.activate(vcam, 0.5)                   # 切机位, 0.5 秒过渡
## CameraTool.deactivate(vcam)                      # 退出机位, 回落上一个
## CameraTool.find(game_root, &"ResultCamera")      # 按节点名找机位
## CameraTool.snap()                                # 立即对齐当前机位
## CameraTool.impulse(hit_pos, 1.0)                 # 定向冲击: 从爆点扩散, 按距离衰减
## CameraTool.shake(0.6)                            # 无方向震屏
## [/codeblock]
class_name CameraTool

## 冲击位移的世界缩放: strength=1 时相机最大偏移约 0.35 米
const IMPULSE_POSITION_SCALE := 0.35
## 冲击旋转的世界缩放: strength=1 时相机最大偏转约 3 度
const IMPULSE_ROTATION_SCALE := 3.0
## 单次冲击的振荡周期数(衰减正弦)
const IMPULSE_OSCILLATIONS := 2.5
## 冲击传播速度(米/秒): 越远越晚被"震到", 制造冲击波掠过的层次感
const IMPULSE_SPEED := 40.0

## 进行中的冲击; 每项为 Dictionary{origin, strength, radius, duration, start, seed}
static var _impulses: Array[Dictionary] = []
## 无方向震屏(origin 为 null)
static var _shake: Dictionary = {}

## 轮转调度(ROUND_ROBIN 策略)的游标与当前被选中的机位
static var _rr_index: int = 0
static var _rr_active: VirtualCamera3D = null


# ── 查询 ──

## 当前场景的相机大脑(不在场景树中时返回 null)
static func get_brain() -> CameraBrain3D:
	var brain := CameraBrain3D.main
	if brain == null or not is_instance_valid(brain) or not brain.is_inside_tree():
		return null
	return brain


## 真实渲染相机: 优先 Brain, 否则退回视口当前相机(兼容没有 Brain 的场景)
static func get_camera() -> Camera3D:
	var brain := get_brain()
	if brain != null:
		return brain
	var loop := Engine.get_main_loop() as SceneTree
	return loop.root.get_camera_3d() if loop != null else null


## 当前生效机位
static func get_current() -> VirtualCamera3D:
	return VirtualCamera3D.current


# ── 机位切换 ──

## 切到指定机位; blend < 0 时使用机位自身/Brain 的默认过渡时长
static func activate(vcam: VirtualCamera3D, blend: float = -1.0) -> void:
	if vcam == null or not is_instance_valid(vcam):
		return
	vcam.activate(blend)


## 退出指定机位(自动回落到上一个仍激活的机位)
static func deactivate(vcam: VirtualCamera3D) -> void:
	if vcam == null or not is_instance_valid(vcam):
		return
	vcam.deactivate()


## 按节点名在子树中查找机位(便于代码侧无需持有引用)
static func find(root: Node, camera_name: StringName) -> VirtualCamera3D:
	if root == null or not is_instance_valid(root):
		return null
	return root.find_child(String(camera_name), true, false) as VirtualCamera3D


## 立即对齐当前机位(无过渡), 用于传送 / 场景切换后消除拖影
static func snap() -> void:
	var brain := get_brain()
	if brain != null:
		brain.snap_to_current()


# ── 冲击 / 震屏 ──

## 定向冲击: 从 origin 向外传播, 相机越远震得越轻越晚(对齐 Cinemachine Impulse)。
## radius 为影响半径(米), 超出则完全无感; duration 为单次冲击持续时间(秒)。
static func impulse(origin: Vector3, strength: float = 1.0, radius: float = 25.0, duration: float = 0.5) -> void:
	if strength <= 0.0 or radius <= 0.0 or duration <= 0.0:
		return
	_impulses.append({
		origin = origin,
		strength = strength,
		radius = radius,
		duration = duration,
		start = _now(),
		seed = randi() % 100000,
	})


## 无方向震屏(全屏抖动), 用于爆炸在画面外 / 纯 UI 反馈等没有爆点的场合。
## direction 为位移主方向(世界空间, 单位向量即可, 旋轉抖動不受其影响):
## 传相机右向可实现"受击向侧后方 punch"的打击感, 默认全向。
static func shake(strength: float = 1.0, duration: float = 0.4, direction: Vector3 = Vector3.ZERO) -> void:
	if strength <= 0.0 or duration <= 0.0:
		return
	_shake = {strength = strength, duration = duration, start = _now(), direction = direction}


## 清空所有进行中的冲击与震屏
static func clear_impulses() -> void:
	_impulses.clear()
	_shake = {}


## 采样冲击对指定位置的贡献, 返回 {position: Vector3(世界空间), rotation: Vector3(世界空间, 弧度)}
static func sample_impulse(cam_position: Vector3) -> Dictionary:
	var pos := Vector3.ZERO
	var rot := Vector3.ZERO
	var now := _now()
	for i in range(_impulses.size() - 1, -1, -1):
		var imp: Dictionary = _impulses[i]
		var amp := _impulse_amplitude(imp, cam_position, now, true)
		if amp <= 0.0:
			if now - float(imp.get("start", 0.0)) > float(imp.get("duration", 0.0)) + 5.0:
				_impulses.remove_at(i)
			continue
		var wave := _impulse_wave(imp, cam_position, now)
		var dir := (cam_position - Vector3(imp.origin)).normalized()
		var seed_v: float = float(imp.get("seed", 0))
		pos += dir * amp * wave * IMPULSE_POSITION_SCALE
		rot += Vector3(
			sin(wave * 2.7 + seed_v),
			sin(wave * 3.1 + seed_v * 0.7),
			sin(wave * 1.9 + seed_v * 1.3),
		) * amp * wave * IMPULSE_ROTATION_SCALE * (PI / 180.0)
	if not _shake.is_empty():
		var amp := _impulse_amplitude(_shake, cam_position, now, false)
		if amp > 0.0:
			var wave := _impulse_wave(_shake, cam_position, now)
			var dir: Vector3 = _shake.get("direction", Vector3.ONE)
			pos += Vector3(sin(wave * 5.1), sin(wave * 6.3 + 1.7), sin(wave * 4.7 + 3.1)) * dir * amp * wave * IMPULSE_POSITION_SCALE
			rot += Vector3(sin(wave * 3.7 + 0.5), sin(wave * 4.3 + 2.1), sin(wave * 2.9 + 4.4)) * amp * wave * IMPULSE_ROTATION_SCALE * (PI / 180.0)
		else:
			_shake = {}
	return {position = pos, rotation = rot}


## 冲击包络: 传播延迟 × 距离衰减 × 时间衰减; 0 表示此刻无贡献
static func _impulse_amplitude(imp: Dictionary, cam_position: Vector3, now: float, directional: bool) -> float:
	var elapsed: float = now - float(imp.get("start", 0.0))
	var duration: float = float(imp.get("duration", 0.0))
	var delay: float = 0.0
	var origin := Vector3.ZERO
	var atten := 1.0
	if directional:
		origin = Vector3(imp.get("origin", Vector3.ZERO))
		delay = cam_position.distance_to(origin) / IMPULSE_SPEED
		atten = 1.0 - clampf(cam_position.distance_to(origin) / maxf(float(imp.get("radius", 1.0)), 0.0001), 0.0, 1.0)
	var t: float = elapsed - delay
	if t < 0.0 or t > duration:
		return 0.0
	var p: float = t / maxf(duration, 0.0001)
	var falloff := 1.0 - p * p                      # 前段强、尾段快速收敛
	return float(imp.get("strength", 0.0)) * atten * falloff


## 衰减正弦波形, 取值 [-1, 1]; 相位从 0 起振(冲击由弱渐强), seed 只用于各轴的相位扰动
static func _impulse_wave(imp: Dictionary, cam_position: Vector3, now: float) -> float:
	var elapsed: float = now - float(imp.get("start", 0.0))
	var delay: float = 0.0
	if imp.has("origin"):
		delay = cam_position.distance_to(Vector3(imp.origin)) / IMPULSE_SPEED
	var t: float = elapsed - delay
	return sin(t / maxf(float(imp.get("duration", 0.0)), 0.0001) * TAU * IMPULSE_OSCILLATIONS)


static func _now() -> float:
	return Time.get_ticks_msec() * 0.001


# ── 共享数学 ──

## 帧率无关的指数平滑权重: damping 为追上目标的时间常数(秒), <= 0 表示瞬时到位
static func damp_weight(damping: float, delta: float) -> float:
	if damping <= 0.0:
		return 1.0
	return 1.0 - exp(-delta / damping)


## [method damp_weight] 的分轴版本, 用于按轴独立阻尼
static func damp_weight3(damping: Vector3, delta: float) -> Vector3:
	return Vector3(
		damp_weight(damping.x, delta),
		damp_weight(damping.y, delta),
		damp_weight(damping.z, delta),
	)


## 位置混合轨迹
enum BlendStyle {
	LINEAR,       ## 直线插值
	SPHERICAL,    ## 绕枢纽点走球面弧线(需有枢纽点), 相机不会切过目标内部
	CYLINDRICAL,  ## 绕枢纽点走柱面弧线: 水平绕行 + 高度线性
}

## 姿态混合: 旋转恒为四元数 slerp; 位置按 style 走直线 / 球面 / 柱面轨迹。
## pivot 为球面与柱面的枢纽点(通常是瞄准目标), 允许为 null; style 非 LINEAR 但枢纽点缺失时退化为直线。
static func interpolate_transform(from: Transform3D, to: Transform3D, pivot: Variant, weight: float, style: BlendStyle) -> Transform3D:
	if style == BlendStyle.LINEAR or pivot == null:
		return from.interpolate_with(to, weight)
	var p: Vector3 = pivot
	var a := from.origin - p
	var b := to.origin - p
	var ra := a.length()
	var rb := b.length()
	if ra < 0.0001 or rb < 0.0001:
		return from.interpolate_with(to, weight)
	var origin: Vector3
	if style == BlendStyle.CYLINDRICAL:
		var ha := Vector2(a.x, a.z)
		var hb := Vector2(b.x, b.z)
		var angle: float = ha.angle() + wrapf(hb.angle() - ha.angle(), -PI, PI) * weight
		var radius: float = lerpf(ha.length(), hb.length(), weight)
		origin = p + Vector3(cos(angle) * radius, lerpf(a.y, b.y, weight), sin(angle) * radius)
	else:
		var dir_a := a / ra
		var dir_b := b / rb
		var dir := dir_a
		# 近似反向时 slerp 无唯一解, 退化为直线
		if dir_a.dot(dir_b) > -0.9999:
			dir = dir_a.slerp(dir_b, weight)
		origin = p + dir * lerpf(ra, rb, weight)
	return Transform3D(from.basis.slerp(to.basis, weight), origin)


# ── 内部: 未生效机位的轮转调度 ──

## 每帧把一个"待命"机位轮到可更新状态, 让 ROUND_ROBIN 策略下冷机位也能逐步跟上目标
static func _advance_round_robin() -> void:
	var cams := VirtualCamera3D.active_cameras
	if cams.is_empty():
		if _rr_active != null:
			if is_instance_valid(_rr_active):
				_rr_active._set_round_robin(false)
			_rr_active = null
		return
	_rr_index = (_rr_index + 1) % cams.size()
	var next: VirtualCamera3D = cams[_rr_index]
	if next == _rr_active:
		return
	if _rr_active != null and is_instance_valid(_rr_active):
		_rr_active._set_round_robin(false)
	_rr_active = next
	if next != null and is_instance_valid(next):
		next._set_round_robin(true)
