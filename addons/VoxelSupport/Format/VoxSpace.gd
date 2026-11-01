@tool
class_name VoxSpace
extends RefCounted
## MagicaVoxel `.vox` 的**文件约定**（读写两端唯一出处）：坐标轴、朝向编码、模型居中偏移、
## 调色板项下标。它们都是"文件里怎么摆"的约定，不是通用数学。
## 【为什么必须集中】读端与写端各写一份，必然有一处在某个轴上漂一格 —— 而这种错是**静默**的
## （模型整体偏移半个尺寸、旋转方向反了、颜色错位），只有把读写摆在一起才看得见。
## 【调色板为什么不需要偏移】官方格式文档原文：
##     color [0-254] are mapped to palette index [1-255], e.g :
##     for ( int i = 0; i <= 254; i++ ) { palette[i + 1] = ReadRGBA(); }
## 即文件里 256 项（1024 字节）中，**前 255 项对应调色板 1..255**，调色板 0 恒为 0x00000000。
## 于是 `.vox` 的 colorIndex 与 QVX 的材质 ID **天然同基**（1 起、0 = 空气），两端零偏移。
## 实测 demo/deer.vox：colorIndex ∈ [27, 254]、MATL id ∈ [1, 256]，与此吻合。

## 文件里 RGBA 块的项数（每项 4 字节，共 1024 字节）。
const PALETTE_SLOTS := 256
## XYZI 的坐标是 u8，故单边上限。
const MAX_EDGE := 256


# 坐标轴（MagicaVoxel 是 Z-up，Godot 是 Y-up）

static func to_godot_pos(v: Vector3i) -> Vector3i:
	return Vector3i(v.x, v.z, -v.y)


static func to_vox_pos(v: Vector3i) -> Vector3i:
	return Vector3i(v.x, -v.z, v.y)


## 尺寸的轴交换是**对合**（交换 y/z），正逆同式。
static func to_godot_size(v: Vector3i) -> Vector3i:
	return Vector3i(v.x, v.z, v.y)


static func to_vox_size(v: Vector3i) -> Vector3i:
	return Vector3i(v.x, v.z, v.y)


## nTRN 的 `_t` 用同一套轴换算，但它是浮点三元组。
static func to_godot_vec3(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)


static func to_vox_vec3(v: Vector3) -> Vector3:
	return Vector3(v.x, -v.z, v.y)


## 模型居中偏移：MagicaVoxel 的模型以**自己的中心**为原点，读取端据此把体素搬到世界。
## 写端必须把同一个偏移从 nTRN 的 `_t` 里补偿掉，否则所有模型会整体偏半个尺寸。
## 公式与 `VoxAsset.VoxelModel.offset` 逐字一致（那个 setter 是唯一真值来源）。
static func origin_offset(size_godot: Vector3i) -> Vector3i:
	var half := (Vector3(size_godot) / 2.0).floor()
	return Vector3i(-half.x, -half.y, half.z)


# 调色板

## 材质 ID（1..255）→ RGBA 块里的项下标（0..254）。见类注释的官方映射。
static func palette_item(material_id: int) -> int:
	return clampi(material_id - 1, 0, PALETTE_SLOTS - 2)


# 朝向（nTRN 的 `_r`）

## 解码缓存：索引即原始 7 位值；`null` = 非法（不是 24 种朝向之一）。
static var _rotations: Array = []


## 7 位整数 → 轴对齐 Basis。
## MagicaVoxel 把 3×3 朝向矩阵压成 7 位：低 2 位 = 第 1 行非零元所在列、次 2 位 = 第 2 行，
## 第 3 行由"三行必须是 {0,1,2} 的置换"推出，高 3 位是三个轴的符号。
## 【索引不是 0–23】"24 种朝向"说的是结果集合，不是取值区间：合法值恰好 24 个且不连续
## （2, 4, 9, 17, 22, 24, …；**单位矩阵是 4，不是 0**）。故缓存按 128 项建，
## 且绝不能做任何"夹到 0–23"的处理 —— 那会把多个不同朝向静默映射成同一个。
## 非法值（行索引不是置换 / 行列式为 −1 的镜像）一律按恒等返回：既不越界，也不给模型套镜像。
static func decode_rotation(value: int) -> Basis:
	if value < 0 or value > 127:
		return Basis()
	_ensure_rotations()
	var cached: Variant = _rotations[value]
	return cached if cached != null else Basis()


## Basis → 7 位整数；不是 24 种之一返回 -1（调用方据此拒绝写出，绝不取整凑合）。
## 【为什么反查而不是按位拼】编码值不连续、恒等是 4，按位拼极易与官方表错位一格。
static func encode_rotation(basis: Basis) -> int:
	_ensure_rotations()
	for v in 128:
		var cached: Variant = _rotations[v]
		if cached != null and (cached as Basis).is_equal_approx(basis):
			return v
	return -1


static func _ensure_rotations() -> void:
	if not _rotations.is_empty():
		return
	_rotations.resize(128)
	for v in 128:
		_rotations[v] = _build_rotation(v)


## 单个编码 → Basis；非法返回 null（缓存用，故与 decode 的返回值区分开）。
static func _build_rotation(value: int) -> Variant:
	var row0 := value & 3
	var row1 := (value >> 2) & 3
	var row2 := 3 - row0 - row1
	if row0 > 2 or row1 > 2 or row0 == row1 or row2 < 0 or row2 > 2:
		return null
	var sign0 := 1.0 if ((value >> 4) & 1) == 0 else -1.0
	var sign1 := 1.0 if ((value >> 5) & 1) == 0 else -1.0
	var sign2 := 1.0 if ((value >> 6) & 1) == 0 else -1.0
	# 三行各有一个 ±1：第 i 行的非零元落在 rowX 指定的列上，其余为 0
	var cols := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	cols[row0] = Vector3(sign0, 0, 0)
	cols[row1] = Vector3(0, sign1, 0)
	cols[row2] = Vector3(0, 0, sign2)
	var col0: Vector3 = cols[0]
	var col1: Vector3 = cols[1]
	var col2: Vector3 = cols[2]
	# 源格式 Z-up → Godot Y-up：列重排即轴向转换（符号翻转不改变行列式正负）。
	var basis := Basis(
			Vector3(col0.x, col0.z, -col0.y),
			Vector3(col2.x, col2.z, -col2.y),
			Vector3(-col1.x, -col1.z, col1.y))
	return null if basis.determinant() < 0.0 else basis
