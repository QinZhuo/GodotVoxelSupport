class_name VoxelMaterial
extends Resource

## 体素材质 (对应 MagicaVoxel 的材质定义)

## 材质ID (对应 .vox 中的材质索引)
@export var id: int

## 基础颜色
@export var color: Color = Color.WHITE

## 透明度 (0=不透明, >0=透明)
@export var trans: float = 0

@export var metal: float = 0

@export var rough: float = 1

@export var emission: float = 0

## 硬度：破坏该材质的单个体素所需的总伤害 (>=0)
@export var hardness: float = 1.0

## 质量：单个体素的质量 (>=0)
@export var mass: float = 1.0

## 连接强度：体素与相邻体素之间的连接强度（受力传导能力）
@export var connection_strength: float = 10.0

# QVX MATE 条目互转（唯一实现：QVoxelStream 写盘、QVoxelAsset 导入共用）

## 空气条目（MATE 条目 0 的规范形态）。
static func air_mate() -> Dictionary:
	return QVoxelMate.air_entry()

## 这是不是"空条目"（没有颜色、没有金属度、没有自发光）。
static func is_air_entry(entry: Dictionary) -> bool:
	return QVoxelMate.is_air_entry(entry)

## MATE 条目 → 材质。
static func from_mate(entry: Dictionary, id: int = 0) -> VoxelMaterial:
	var rgba := int(entry.get("rgba", 0)) & 0xFFFFFFFF
	var a := float(rgba & 0xFF) / 255.0
	var mat := VoxelMaterial.new()
	mat.id = id
	mat.color = Color(
			float((rgba >> 24) & 0xFF) / 255.0,
			float((rgba >> 16) & 0xFF) / 255.0,
			float((rgba >> 8) & 0xFF) / 255.0, a)
	mat.trans = clampf(1.0 - a, 0.0, 1.0)
	mat.metal = float(int(entry.get("metal", 0))) / 255.0
	mat.rough = float(int(entry.get("rough", 0))) / 255.0
	mat.hardness = float(int(entry.get("hardness", 1)))
	mat.mass = float(int(entry.get("mass", 1)))
	var er := float(int(entry.get("e_r", 0))) / 255.0
	var eg := float(int(entry.get("e_g", 0))) / 255.0
	var eb := float(int(entry.get("e_b", 0))) / 255.0
	mat.emission = maxf(er, maxf(eg, eb))
	return mat

## 材质 → MATE 条目。
static func to_mate(m: Variant) -> Dictionary:
	if m == null:
		return air_mate()
	if m is Dictionary:
		var d: Dictionary = m
		return {
			"rgba": int(d.get("rgba", 0)) & 0xFFFFFFFF,
			"metal": clampi(int(d.get("metal", 0)), 0, 255),
			"rough": clampi(int(d.get("rough", 0)), 0, 255),
			"hardness": clampi(int(d.get("hardness", 0)), 0, 255),
			"mass": clampi(int(d.get("mass", 0)), 0, 255),
			"e_r": clampi(int(d.get("e_r", 0)), 0, 255),
			"e_g": clampi(int(d.get("e_g", 0)), 0, 255),
			"e_b": clampi(int(d.get("e_b", 0)), 0, 255),
		}
	var color: Color = m.color if ("color" in m) else Color.WHITE
	var alpha := 255
	if "trans" in m:
		alpha = clampi(int(round((1.0 - float(m.trans)) * 255.0)), 0, 255)
	var rgba := (int(color.r * 255.0) << 24) | (int(color.g * 255.0) << 16) \
			| (int(color.b * 255.0) << 8) | alpha
	var em: float = float(m.emission) if ("emission" in m) else 0.0
	return {
		"rgba": rgba & 0xFFFFFFFF,
		"metal": clampi(int(round(float(m.metal) * 255.0)), 0, 255) if ("metal" in m) else 0,
		"rough": clampi(int(round(float(m.rough) * 255.0)), 0, 255) if ("rough" in m) else 255,
		"hardness": clampi(int(round(float(m.hardness))), 0, 255) if ("hardness" in m) else 1,
		"mass": clampi(int(round(float(m.mass))), 0, 255) if ("mass" in m) else 1,
		# 【灰度，不乘基色】`e_*` 只承载**强度**：读端（`from_mate`）取三通道最大值还原。
		"e_r": clampi(int(round(em * 255.0)), 0, 255),
		"e_g": clampi(int(round(em * 255.0)), 0, 255),
		"e_b": clampi(int(round(em * 255.0)), 0, 255),
	}

# 材质数组对齐：确保"数组索引 == 材质ID"，体素中存的材质ID可直接作数组索引

## 将任意材质数组转换为"索引 == 材质ID"的对齐数组
static func align_by_id(materials: Array) -> Array:
	var aligned: Array = []
	for mat in materials:
		if mat == null or mat.id <= 0:
			continue
		var mat_id: int = mat.id
		while aligned.size() <= mat_id:
			aligned.append(null)
		aligned[mat_id] = mat
	return aligned

## 材质数组 → 透明标志表（PackedByteArray，索引 = 材质ID，1 = 透明），供原生几何内核
static func build_trans_flags(materials: Array) -> PackedByteArray:
	var n := materials.size()
	var flags := PackedByteArray()
	flags.resize(n)
	for i in n:
		var m: Variant = materials[i] if i < materials.size() else null
		flags[i] = 1 if (m != null and m.trans > 0) else 0
	return flags

# 材质→各通道颜色：所有纹理生成（编辑器文件纹理 / 运行时内存纹理）统一采样公式

## 反照率颜色 (透明材质：用 1-trans 作为 alpha)
static func albedo_color(m: VoxelMaterial) -> Color:
	if m.trans <= 0:
		return m.color
	return Color(m.color.r, m.color.g, m.color.b, 1 - m.trans)

## 金属度灰度
static func metal_color(m: VoxelMaterial) -> Color:
	return Color.from_hsv(0, 0, m.metal)

## 粗糙度灰度
static func rough_color(m: VoxelMaterial) -> Color:
	return Color.from_hsv(0, 0, m.rough)

## 自发光颜色
static func emission_color(m: VoxelMaterial) -> Color:
	return m.color * m.emission

# 材质ID 上限

## 纹理调色板宽度（材质纹理是 256×1），也是"按材质ID 索引的查表类缓冲"
const MAX_MATERIAL_ID := 256

# 存档 / 重建

## 序列化材质为可 JSON 保存的结构（材质自身负责自己的存档）
func save_data() -> Dictionary:
	return {
		"id": id,
		"color": [color.r, color.g, color.b, color.a],
		"trans": trans,
		"metal": metal,
		"rough": rough,
		"emission": emission,
		"hardness": hardness,
		"mass": mass,
		"connection_strength": connection_strength,
	}

## 从序列化数据重建材质属性（静态：需新建材质实例）
static func load_data(data: Variant) -> VoxelMaterial:
	if data == null or not data is Dictionary:
		return null
	var mat := VoxelMaterial.new()
	mat.id = int(data.get("id", 0))
	if data.has("color") and data["color"] is Array and data["color"].size() >= 4:
		var c: Array = data["color"]
		mat.color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	mat.trans = float(data.get("trans", 0.0))
	mat.metal = float(data.get("metal", 0.0))
	mat.rough = float(data.get("rough", 1.0))
	mat.emission = float(data.get("emission", 0.0))
	mat.hardness = float(data.get("hardness", 1.0))
	mat.mass = float(data.get("mass", 1.0))
	mat.connection_strength = float(data.get("connection_strength", 10.0))
	return mat
