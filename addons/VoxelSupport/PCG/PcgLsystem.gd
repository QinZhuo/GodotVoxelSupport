@tool
class_name PcgLsystem
extends PcgModel

## L-系统（Lindenmayer 文法）：公理 + 产生式迭代展开成符号串，再由"乌龟"按符号前进盖章。
##
## 【符号表】（经典 3D 乌龟，ABOP 约定；H/L/U = 乌龟的前/左/上轴）
##   F  前进并盖章        f  前进不盖章
##   +  左转 angle        -  右转 angle        （绕 U，偏航）
##   &  下俯 angle        ^  上仰 angle        （绕 L，俯仰）
##   /  左滚 angle        \  右滚 angle        （绕 H，横滚）
##   |  掉头 180°
##   [  压栈（记住位置与朝向）   ]  出栈
## 其余字符原样复制、不产生动作——方便用 X/Y 之类符号做"只参与改写、不参与绘制"的占位符。
##
## 【确定性】纯字符串改写 + 固定起点，同参数同 grid_size 恒得同一棵树。
##
## 【起点】模型底面中心，初始朝向为 +Y（向上生长），因此默认产生的是"树 / 灌木"这类造型。


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

## 展开上限：L-系统是指数增长，超出即截断（防止一次误设参数挂住编辑器）。
const MAX_SYMBOLS := 100_000
const MAX_ITERATIONS := 8


func build(grid_size: Vector3i) -> PackedInt32Array:
	var volume := PcgModel.empty_volume(grid_size)
	if volume.is_empty():
		return volume
	_draw(volume, grid_size, _expand())
	return volume


# ----------------------------------------------------------------------------
# ① 改写：把公理按产生式迭代展开成符号串
# ----------------------------------------------------------------------------

func _expand() -> String:
	var table := {}
	for r in rules:
		var eq := r.find("=")
		if eq <= 0:
			continue
		table[r.substr(0, eq)] = r.substr(eq + 1)

	var current := axiom
	for _i in mini(maxi(iterations, 0), MAX_ITERATIONS):
		var parts := PackedStringArray()
		for i in current.length():
			var ch := current[i]
			parts.append(table.get(ch, ch))
		current = "".join(parts)
		if current.length() > MAX_SYMBOLS:
			return current.substr(0, MAX_SYMBOLS)
	return current


# ----------------------------------------------------------------------------
# ② 绘制：乌龟走一遍符号串
# ----------------------------------------------------------------------------

func _draw(volume: PackedInt32Array, grid_size: Vector3i, symbols: String) -> void:
	var angle := deg_to_rad(angle_degrees)
	# 初始朝向 +Y：Basis(RIGHT, 90°) 恰好把 FORWARD 映射到 UP。
	var pos := Vector3(grid_size.x * 0.5, 1.0, grid_size.z * 0.5)
	var basis := Basis(Vector3.RIGHT, PI * 0.5)
	var stack: Array = []

	for i in symbols.length():
		match symbols[i]:
			"F":
				var next := pos + basis * Vector3.FORWARD * step
				_stamp_segment(volume, grid_size, pos, next)
				pos = next
			"f":
				pos += basis * Vector3.FORWARD * step
			"+":
				basis = basis.rotated(basis * Vector3.UP, angle)
			"-":
				basis = basis.rotated(basis * Vector3.UP, -angle)
			"&":
				basis = basis.rotated(basis * Vector3.LEFT, angle)
			"^":
				basis = basis.rotated(basis * Vector3.LEFT, -angle)
			"/":
				basis = basis.rotated(basis * Vector3.FORWARD, angle)
			"\\":
				basis = basis.rotated(basis * Vector3.FORWARD, -angle)
			"|":
				basis = basis.rotated(basis * Vector3.UP, PI)
			"[":
				stack.append([pos, basis])
			"]":
				if not stack.is_empty():
					var saved: Array = stack.pop_back()
					pos = saved[0]
					basis = saved[1]


## 在 from→to 之间按半体素间隔采样盖章 —— 步长大于 1 体素时不留缝隙。
func _stamp_segment(volume: PackedInt32Array, grid_size: Vector3i,
		from: Vector3, to: Vector3) -> void:
	var spans := maxi(int(ceil(from.distance_to(to) / 0.5)), 1)
	for i in spans + 1:
		_stamp(volume, grid_size, from.lerp(to, float(i) / float(spans)))


## 以 p 为中心盖一个半径 thickness 的球。
func _stamp(volume: PackedInt32Array, grid_size: Vector3i, p: Vector3) -> void:
	var r := maxf(thickness, 0.5)
	var lo := (p - Vector3(r, r, r)).floor()
	var hi := (p + Vector3(r, r, r)).ceil()
	for z in range(int(lo.z), int(hi.z) + 1):
		for y in range(int(lo.y), int(hi.y) + 1):
			for x in range(int(lo.x), int(hi.x) + 1):
				if Vector3(x + 0.5, y + 0.5, z + 0.5).distance_squared_to(p) <= r * r:
					PcgModel.set_voxel(volume, x, y, z, grid_size, material_id)
