@tool
class_name PcgLsystem
extends PcgModel

## L-系统（Lindenmayer 文法）：公理 + 产生式迭代展开成符号串，再由"乌龟"按符号前进盖章。
## 【符号表】（经典 3D 乌龟，ABOP 约定；H/L/U = 乌龟的前/左/上轴）
##   F  前进并盖章        f  前进不盖章
##   +  左转 angle        -  右转 angle        （绕 U，偏航）
##   &  下俯 angle        ^  上仰 angle        （绕 L，俯仰）
##   /  左滚 angle        \  右滚 angle        （绕 H，横滚）
##   |  掉头 180°
##   [  压栈（记住位置与朝向）   ]  出栈
## 其余字符原样复制、不产生动作——方便用 X/Y 之类符号做"只参与改写、不参与绘制"的占位符。
## 【确定性】同参数同 grid_size 恒得同一棵树（固定 seed，不使用全局随机）。
## 【起点】模型底面中心，初始朝向为 +Y（向上生长），因此默认产生的是"树 / 灌木"这类造型。
## 【精致化三件套】下面三个参数默认全为 0 / 关闭，即**默认行为与旧版逐体素一致**；
## 开启后才获得"自然"观感，用于同一套文法长出外形互不相同的成片植被：
##   seed + variation —— 起始朝向 / 转角 / 步长 / 盖章半径抖动（变体差异）
##   taper          —— 枝干随分叉深度渐细（根粗梢细，否则像一串等粗棍子）
##   tip_material_id—— 末梢额外盖一个叶团并换成第二种材质（区分枝干与叶片）


## 公理（迭代的起点符号串）。
@export_multiline var axiom: String = "F"
## 产生式，每项形如 "F=FF+[+F-F-F]"。左侧必须是单个字符，其余项忽略。
@export var rules: PackedStringArray = PackedStringArray(["F=FF+[+F-F-F]-[-F+F+F]"])
## 迭代次数（上限见 MAX_ITERATIONS）。
@export var iterations: int = 3
## 每步前进的体素距离。
@export var step: float = 2.0
## 盖章半径（体素）—— 枝干粗细的一半。
@export var thickness: float = 0.9
## 转向角（度）。90 度会得到直角造型，20~30 度得到自然的分枝。
@export var angle_degrees: float = 24.0
## 枝干材质 ID。
@export var material_id: int = 1

## 随机种子。同一 seed + 同一参数恒得同一棵树（确定性契约）。
## 与 variation 配合：同一套文法 + 不同 seed → 外形互不相同的多棵树，
## 而不必像旧 demo 那样为每棵树手写一份参数配置。
@export var seed: int = 0
## 随机化强度 0~1。0 = 完全不掷骰（逐体素等同旧版）；1 = 大幅抖动。
## 只作用于 [起始朝向, 转角, 步长, 盖章半径] 四处，**不改变文法的拓扑结构**，
## 因此永远不会长出"断裂的树"这类无效形态。
@export_range(0.0, 1.0) var variation: float = 0.0
## 枝干沿分叉深度的渐细比例：0 = 恒定粗细；1 = 每深一层乘 0.5。
## 真实树枝根粗梢细，恒定粗细会让树看起来像一串等粗的棍子。
@export_range(0.0, 1.0) var taper: float = 0.0
## `tip_scope` 的取值。
enum TipScope { ALL_F, BRANCH_END }

## 末梢（最后一轮迭代长出的 F）额外盖一个球团，材质用这个 ID。0 = 关闭。
## 开启后可用两个材质 ID 区分"枝干 / 叶片"——这是本栈实现分区多材质的入口。
@export var tip_material_id: int = 0
## 末梢球团半径（体素）。
@export var tip_radius: float = 1.0
## 叶团盖在哪些 F 上（仅 `tip_material_id > 0` 时生效）。
##   全部 F   —— 旧语义：`深度 == 最大深度` 即末梢。
##   分支末梢 —— 每个括号层的最后一个 F。
@export_enum("全部 F（旧语义）", "分支末梢") var tip_scope: int = TipScope.ALL_F
## 叶团只填空位、不改写已经盖好的枝干（仅 `tip_material_id > 0` 时生效）。
## 【为什么默认开 —— 不开的话树干会被叶子吃光】盖章顺序是"先盖这段枝干、
## 再在末端盖叶球"，叶球是**无条件覆盖**写入的。于是当 `tip_radius ≥ step` 时，
## 末端叶球把刚盖好的整段枝条连同它一起涂成叶色。实测森林 demo
## （`tip_radius = 2.0`、`step = 1.5`）一棵树 1291 个实心体素里只剩 21 个是木头
##（1.6%），看上去就是一坨没有树干的绿雾。打开后木头永远优先，叶子只长在枝条
## 周围的空气里 —— 树冠包住枝端、树干露出来。
@export var tip_air_only: bool = true

## 展开上限：L-系统是指数增长，超出即截断（防止一次误设参数挂住编辑器）。
const MAX_SYMBOLS := 100_000
const MAX_ITERATIONS := 8

## variation 各抖动项的幅度（乘以 variation 后作为 ± 比例）。
const JIT_ANGLE := 0.35
const JIT_STEP := 0.18
const JIT_THICK := 0.25
const JIT_YAW := 1.0
const JIT_TILT := 4.0


## 把单符号文法 `F=<body>` 改写成"起步 + 分枝"的两段式规则集：
##   A=FFX    —— 先铺两段**不分枝**的裸露主干
##   X=<body> —— 括号**外**的 F 原样保留（它们是"长一段"，必须继续画出体素），
##               括号**内**的 F 换成 X（只有它们才是递归点）
## 【为什么必须这样做 —— 这是实测出来的，不是风格偏好】`F=FF[...]` 这类经典文法
## 第一步就是分枝，从 axiom 直接起步的话树干每长一步就分叉、叶子从地面开始裹，
## 长出来是**灌木**不是树（实测森林 demo 一棵"树"的木头只占实心体素的 1.6%，
## 屏幕上找不到一根裸露主干）。改造后原文法的**分枝结构一字未改**，
## 改的只是"从哪根符号开始长"，所以多套文法并排时依旧可比。
## 【为什么不能把 F 无差别全换成 X】那样括号外的 F 也变成只递归不画的 X，
## 展开到底后字符串里只剩 X，乌龟一路走过去什么都不盖 —— 整棵树只剩 `A=FFX` 两段。
## 故只换**括号深度 > 0** 的 F。
## 【用法】配合 `axiom = "A"`：`tree.rules = PcgLsystem.two_stage("F=FF[+F][-F]")`。
static func two_stage(rule: String) -> PackedStringArray:
	var eq := rule.find("=")
	if eq <= 0:
		return PackedStringArray([rule])
	var body := rule.substr(eq + 1)
	var out := ""
	var depth := 0
	for i in body.length():
		var ch := body[i]
		if ch == "[":
			depth += 1
		elif ch == "]":
			depth = maxi(depth - 1, 0)
		out += "X" if (ch == "F" and depth > 0) else ch
	return PackedStringArray(["A=FFX", "X=" + out])


func build(grid_size: Vector3i) -> PackedInt32Array:
	var volume := PcgModel.empty_volume(grid_size)
	if volume.is_empty():
		return volume
	var ex := _expand_with_depths()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	_draw(volume, grid_size, ex["s"], ex["d"], rng)
	return volume


# ① 改写：把公理按产生式迭代展开成符号串

## 只要符号串的视图（不带深度），用于"只要展开结果"的调用方与回归用例
## （test_pcg_operators 据此校验 MAX_SYMBOLS / MAX_ITERATIONS 两条封顶契约）。
func _expand() -> String:
	return _expand_with_depths()["s"]


## 返回 {"s": 展开后的符号串, "d": 与符号串等长的各符号迭代深度}。
## 深度用于两件事：枝干渐细（taper）与末梢判定（深度 == 最大深度者即末梢）。
func _expand_with_depths() -> Dictionary:
	var table := {}
	for r in rules:
		var eq := r.find("=")
		if eq <= 0:
			continue
		table[r.substr(0, eq)] = r.substr(eq + 1)

	var current := axiom
	var depths := PackedInt32Array()
	depths.resize(current.length())
	var rounds := mini(maxi(iterations, 0), MAX_ITERATIONS)
	for _i in rounds:
		var parts := PackedStringArray()
		var next_depths := PackedInt32Array()
		for i in current.length():
			var ch := current[i]
			var sub: String = table.get(ch, ch)
			parts.append(sub)
			var d := depths[i] + 1
			for _k in sub.length():
				next_depths.append(d)
		current = "".join(parts)
		depths = next_depths
		if current.length() > MAX_SYMBOLS:
			current = current.substr(0, MAX_SYMBOLS)
			depths = depths.slice(0, MAX_SYMBOLS)
			break
	return {"s": current, "d": depths}


# ② 绘制：乌龟走一遍符号串

func _draw(volume: PackedInt32Array, grid_size: Vector3i,
		symbols: String, depths: PackedInt32Array, rng: RandomNumberGenerator) -> void:
	var angle := deg_to_rad(angle_degrees)
	var max_d := 0
	for i in depths.size():
		max_d = maxi(max_d, depths[i])

	var pos := Vector3(grid_size.x * 0.5, 1.0, grid_size.z * 0.5)
	var basis := Basis(Vector3.RIGHT, PI * 0.5)
	if variation > 0.0:
		# 起始偏航整体随机：否则同一文法的所有变体都朝同一面，成片摆放时会看出重复。
		basis = basis.rotated(basis * Vector3.UP, rng.randf_range(-PI, PI) * JIT_YAW * variation)
		# 极小的倾角，让主干不是绝对笔直。
		basis = basis.rotated(basis * Vector3.RIGHT,
				deg_to_rad(rng.randf_range(-JIT_TILT, JIT_TILT) * variation))
	var stack: Array = []  # 每项 [pos, basis, branch_depth]
	var branch_depth := 0  # 分支嵌套深度（`[` 加一）：即"离主干多远"，是渐细的正确依据
	# 逐符号的"要不要盖叶团"在热循环**之前**一次算完，循环里只查表。
	var tips := _tip_flags(symbols, depths, max_d)

	for i in symbols.length():
		match symbols[i]:
			"F":
				var th := _thickness_at(branch_depth) * _jit(JIT_THICK, rng)
				var st := step * _jit(JIT_STEP, rng)
				var next := pos + basis * Vector3.FORWARD * st
				_stamp_segment(volume, grid_size, pos, next, th, tips[i] == 1)
				pos = next
			"f":
				pos += basis * Vector3.FORWARD * step * _jit(JIT_STEP, rng)
			"+":
				basis = basis.rotated(basis * Vector3.UP, _jangle(angle, rng))
			"-":
				basis = basis.rotated(basis * Vector3.UP, -_jangle(angle, rng))
			"&":
				basis = basis.rotated(basis * Vector3.LEFT, _jangle(angle, rng))
			"^":
				basis = basis.rotated(basis * Vector3.LEFT, -_jangle(angle, rng))
			"/":
				basis = basis.rotated(basis * Vector3.FORWARD, _jangle(angle, rng))
			"\\":
				basis = basis.rotated(basis * Vector3.FORWARD, -_jangle(angle, rng))
			"|":
				basis = basis.rotated(basis * Vector3.UP, PI)
			"[":
				stack.append([pos, basis, branch_depth + 1])
			"]":
				if not stack.is_empty():
					var saved: Array = stack.pop_back()
					pos = saved[0]
					basis = saved[1]
					branch_depth = saved[2]


## 逐符号判定"这个 F 结尾要不要盖叶团"。`tip_material_id <= 0` 时全部为 0，
## 与旧行为（is_tip 恒 false）一致。
func _tip_flags(symbols: String, depths: PackedInt32Array, max_d: int) -> PackedByteArray:
	var flags := PackedByteArray()
	flags.resize(symbols.length())
	if tip_material_id <= 0:
		return flags
	if tip_scope == TipScope.BRANCH_END:
		return _branch_terminals(symbols)
	var n := mini(depths.size(), symbols.length())
	for i in n:
		if depths[i] >= max_d:
			flags[i] = 1
	return flags


## 【为什么需要"分支末梢"这一档 —— 旧语义其实一个"末梢"都不是】
## 旧判定是 `深度 == 最大深度`。但 `_expand_with_depths` 对**每个**符号（包括 `[` `]`
## `+` `-` 这些不参与改写的字符）都做 `depth + 1`，于是展开 N 轮后所有符号深度
## 一律等于 N：实测 3 轮展开 1388 个符号，`depth_hist = {3: 1388}`，512 个 F
## **全部**命中"末梢"。结果是每个分枝关节都盖一团叶子 —— 连主干也不例外，
## 树被绿团从头裹到脚，读作一团绿雾，树干完全看不见。
## 【判定规则】末梢就是"这一层括号走到头时的最后一个 F"。一次前向扫描即可：
## 维护 `层深 -> 该层最后一个 F 下标`，遇到 `]` 就把该层的候选项盖章为末梢，
## 字符串结束时再补上第 0 层的那一个。之所以能只取"最后一个"，是因为同一层里
## 若后面还有 F，说明本 F 之后枝条仍在延伸（`F` 后面平级再接 `F` 就是续接），
## 那它必然是中间节点而非枝端。
static func _branch_terminals(symbols: String) -> PackedByteArray:
	var flags := PackedByteArray()
	flags.resize(symbols.length())
	var last_f := {}      # 层深 -> 该层尚未定论的 F 下标
	var level := 0
	for i in symbols.length():
		var ch := symbols[i]
		if ch == "[":
			level += 1
		elif ch == "]":
			if level > 0:
				if last_f.has(level):
					flags[last_f[level]] = 1
				level -= 1
		elif ch == "F":
			last_f[level] = i
	if last_f.has(0):
		flags[last_f[0]] = 1
	return flags


## 渐细后的盖章半径（按分支嵌套深度）。taper = 0 时恒为 thickness（与旧版逐体素一致）。
func _thickness_at(branch_depth: int) -> float:
	if taper <= 0.0:
		return maxf(thickness, 0.5)
	var k := pow(1.0 - taper * 0.5, float(branch_depth))
	return maxf(thickness * k, 0.5)


## 比例抖动 1±(amount × variation)；variation = 0 时完全不掷骰（保证旧行为可复现）。
func _jit(amount: float, rng: RandomNumberGenerator) -> float:
	if variation <= 0.0 or amount <= 0.0:
		return 1.0
	return rng.randf_range(1.0 - amount * variation, 1.0 + amount * variation)


## 转角抖动（比例式，不改变平均分枝角度，只让每根枝的方向不一致）。
func _jangle(angle: float, rng: RandomNumberGenerator) -> float:
	if variation <= 0.0 or JIT_ANGLE <= 0.0:
		return angle
	return angle * rng.randf_range(1.0 - JIT_ANGLE * variation, 1.0 + JIT_ANGLE * variation)


## 在 from→to 之间按半体素间隔采样盖章 —— 步长大于 1 体素时不留缝隙。
func _stamp_segment(volume: PackedInt32Array, grid_size: Vector3i,
		from: Vector3, to: Vector3, radius: float, tip: bool) -> void:
	var spans := maxi(int(ceil(from.distance_to(to) / 0.5)), 1)
	for i in spans + 1:
		_stamp(volume, grid_size, from.lerp(to, float(i) / float(spans)), radius, material_id)
	if tip:
		_stamp(volume, grid_size, to, maxf(tip_radius, 0.5), tip_material_id, tip_air_only)


## 以 p 为中心盖一个半径 radius 的球，写入指定材质。
## `only_air` 为 true 时只填**空位**，已有体素一律保留（用于叶团，见 `tip_air_only`）。
func _stamp(volume: PackedInt32Array, grid_size: Vector3i,
		p: Vector3, radius: float, mat_id: int, only_air := false) -> void:
	var r := maxf(radius, 0.5)
	var lo := (p - Vector3(r, r, r)).floor()
	var hi := (p + Vector3(r, r, r)).ceil()
	for z in range(int(lo.z), int(hi.z) + 1):
		for y in range(int(lo.y), int(hi.y) + 1):
			for x in range(int(lo.x), int(hi.x) + 1):
				if not (Vector3(x + 0.5, y + 0.5, z + 0.5).distance_squared_to(p) <= r * r):
					continue
				# set_voxel 自带边界裁剪，但这里要**读**，必须先自己判界。
				if only_air and x >= 0 and y >= 0 and z >= 0 \
						and x < grid_size.x and y < grid_size.y and z < grid_size.z \
						and volume[PcgModel.index_of(x, y, z, grid_size)] != 0:
					continue
				PcgModel.set_voxel(volume, x, y, z, grid_size, mat_id)
