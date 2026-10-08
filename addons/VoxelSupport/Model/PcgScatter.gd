@tool
class_name PcgScatter
extends RefCounted

## 散布器 —— 在区域内按密度与最小间距撒出一组带随机变换的摆放结果。
##
## 【为什么需要它】三条产出栈（WFC / SDF / L-系统）都只管"一个模型长什么样"，
## 但**成组摆放的观感**几乎完全由"撒在哪、转多少、大多大"决定：等间距 + 零旋转 +
## 等比缩放是"人工摆放"的典型特征，也是 demo 场景廉价感的最大来源。这一层与
## "模型怎么生成"正交，故独立于三条栈之外。
##
## 【不重造轮子】① 随机数用引擎自带 `RandomNumberGenerator`（可设 seed，确定性）；
## ② 密度衰减直接用 `FastNoiseLite` 的 2D fbm 采样，不自己写噪声；
## ③ 法线对齐用引擎自带 `Quaternion(arc_from, arc_to)` 构造旋转，不手写四元数。
##
## 【确定性】同 seed + 同参数恒得同一组摆放（含每个结果的 variant_seed），
## 故 variant_seed 可直接喂给 PcgLsystem.seed —— 「同一套文法长出 N 棵不同的树」
## 的位置与形态都由一个种子决定，完全可复现。
##
## 【采样算法：格子抖动 + 最小间距拒收】把区域切成 spacing×spacing 的格，每格随机
## 取一点，再按密度与最小间距拒收。相比纯随机撒点，它天然避免"紧挨成团 + 大片空白"
## 的分布，且是 O(候选数)，无需 Poisson 磁盘采样的邻域搜索。
##
## 【链外节点（P3-4）—— 刻意的，不是遗漏】散布器**不进修改器链**，而且它连
## PcgModel / PcgDetail 都不是（`extends RefCounted`）：它的输入输出是"世界坐标 + 变换"，
## 不产体素也不吃体素，属于**链之后的摆放阶段**。若把它接进链，就得凭空给链定义
## "世界坐标从哪来""摆放结果算不算体积"这类与域模型冲突的概念。
## 它消费链的产物（某个体素模型），而不是成为链的一环 —— 判据见 PcgModel.chainable()。


## 地面查询返回值约定：{"y": float, "normal": Vector3}（normal 可省略）。
const GROUND_KEY_Y := "y"
const GROUND_KEY_NORMAL := "normal"

## 散布结果：世界变换 + 形态变体种子。
class Placement extends RefCounted:
	## 世界变换（位置已吸附到地面高度，含随机旋转与缩放）。
	var xform: Transform3D
	## 形态变体种子。喂给 PcgLsystem.seed 之类，让每个实例形态不同。
	var variant_seed: int


## 区域中心（世界 XZ）。
@export var center: Vector2 = Vector2.ZERO
## 区域半径（世界单位）。散布点在以 center 为心的圆内而非方形——
## 方形边界在镜头里会露出"一刀切"的直边。
@export var radius: float = 20.0
## 目标数量（实际数量受密度与间距约束，通常小于此值）。
@export var count: int = 20
## 最小间距（世界单位）。这是"不显得人工"的第一要素。
@export var spacing: float = 4.0
## 间距随机抖动 0~1：每点的实际间距要求为 spacing × [1-jitter, 1+jitter]。
## 只有 min-distance 的撒点间距仍偏一致，加抖动后才像自然生长。
@export_range(0.0, 1.0) var spacing_jitter: float = 0.4
## 密度上限 0~1（1 = 满密度），与噪声相乘得到接受概率。
@export_range(0.0, 1.0) var density: float = 0.6
## 密度噪声尺度（世界单位）。越小越成片，越大越成簇。
@export var density_scale: float = 12.0
## 中心留空半径（世界单位）。用于"林间空地 / 广场"，
## 避免景物堆在场景正中挡住主体。
@export var inner_radius: float = 0.0
## 随机种子。同种子恒得同一组结果。
@export var seed: int = 0
## 缩放下限 / 上限。给一点体积差比完全等比自然得多。
@export var scale_min: float = 0.85
@export var scale_max: float = 1.15
## 是否按地面法线倾斜（false 则一律竖直）。
@export var align_to_normal: bool = false
## 最大倾角（度）。即使对齐法线也限制在此值内 —— 超过 ~35° 的树会显得要倒。
@export_range(0.0, 89.0) var max_tilt_degrees: float = 25.0
## Y 轴随机旋转幅度（度）。0 = 不转。树的朝向全随机才不像复制粘贴。
@export_range(0.0, 360.0) var yaw_degrees: float = 360.0
## 地面查询：`ground_query.call(Vector2(x, z))` → Dictionary（见 GROUND_KEY_*），
## 或返回 null / y 为 NAN 表示该点不可放置。不设则全部落在 y = 0 的平面上。
## 由调用方注入（读高度图、射线检测、或直接给常数），本类不假设地形形态。
@export var ground_query: Callable = Callable()


## 采点 + 生成摆放结果。确定性：同 seed 同参数恒得同一数组。
func generate() -> Array:
	var out: Array = []
	if count <= 0 or radius <= 0.0 or spacing <= 0.0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	# 密度场直接用引擎自带噪声，不自研：两倍频 fbm 已足够表现"疏密成片"。
	var noise := FastNoiseLite.new()
	noise.seed = seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	# FastNoiseLite 用的是 frequency（每单位坐标的频率），与 OpenSimplexNoise 的
	# noise_scale 正好相反。density_scale 的语义是"特征的世界尺寸"，故取其倒数。
	noise.frequency = 1.0 / maxf(density_scale, 0.001)
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2

	var accepted: Array[Vector2] = []   # 已接受的 XZ，用于最小间距拒收
	var step := spacing
	var gx := center.x - radius
	while gx <= center.x + radius:
		var gz := center.y - radius
		while gz <= center.y + radius:
			# 每格取一点：格内均匀抖动，比纯随机撒点更均匀且天然近似 min-distance
			var p := Vector2(gx + rng.randf() * step, gz + rng.randf() * step)
			gz += step
			var d := p.distance_to(center)
			if d > radius or d < inner_radius:
				continue
			# 噪声 [-1,1] → [0,1]，×2 后与 density 相乘（density=1 时噪声满格才通过）
			var n01 := (noise.get_noise_2d(p.x, p.y) + 1.0) * 0.5 * 2.0
			if rng.randf() > density * n01:
				continue
			# 最小间距拒收（带抖动）；用平方距离免开方
			var need := spacing * rng.randf_range(1.0 - spacing_jitter, 1.0 + spacing_jitter)
			var need_sq := need * need
			var too_close := false
			for a in accepted:
				if p.distance_squared_to(a) < need_sq:
					too_close = true
					break
			if too_close:
				continue
			accepted.append(p)
			var pl := _make_placement(p, rng)
			if pl != null:
				out.append(pl)
			if out.size() >= count:
				return out
		gx += step
	return out


## 组成一个 Placement：吸附地面高度 + 随机 yaw + 随机缩放 + 可选法线对齐。
## 地面查询返回 null / NAN 时返回 null（该点不可放置，已计入间距但不出结果）。
func _make_placement(p: Vector2, rng: RandomNumberGenerator) -> Placement:
	var pos := Vector3(p.x, 0.0, p.y)
	var ground_normal := Vector3.UP
	if ground_query.is_valid():
		var hit: Variant = ground_query.call(p)
		if hit is Dictionary:
			var g: Dictionary = hit
			if not g.has(GROUND_KEY_Y):
				return null
			var y: float = g[GROUND_KEY_Y]
			if is_nan(y):
				return null
			pos.y = y
			if g.has(GROUND_KEY_NORMAL):
				ground_normal = g[GROUND_KEY_NORMAL]
		else:
			return null

	# 倾角限制：把法线朝 UP 回退到最大倾角内（球面插值，比例 = 超出角度占比）
	if align_to_normal:
		if ground_normal.length_squared() < 0.000001:
			ground_normal = Vector3.UP
		ground_normal = ground_normal.normalized()
		var max_tilt := deg_to_rad(max_tilt_degrees)
		var ang := ground_normal.angle_to(Vector3.UP)
		if ang > max_tilt:
			ground_normal = ground_normal.slerp(Vector3.UP, 1.0 - max_tilt / ang)

	# 先绕自身 Y 随机旋转（yaw），再整体对齐到地面法线（对齐要在世界空间做，故乘在左侧）
	var basis := Basis(Vector3.UP, deg_to_rad(rng.randf_range(0.0, yaw_degrees)))
	if align_to_normal:
		basis = Basis(Quaternion(Vector3.UP, ground_normal)) * basis
	var s := rng.randf_range(scale_min, scale_max)
	basis = basis.scaled(Vector3(s, s, s))

	var pl := Placement.new()
	pl.xform = Transform3D(basis, pos)
	pl.variant_seed = rng.randi()
	return pl
