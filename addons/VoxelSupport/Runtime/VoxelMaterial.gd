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
## 体素健康度系统使用，伤害累积达到 hardness 才真正移除该体素
## 值越大越难破坏 (0 表示一击即碎，如玻璃/泡沫)
@export var hardness: float = 1.0

## 质量：单个体素的质量 (>=0)
## 悬空崩塌时，整块刚体的质量 = 块内体素质量之和；材质越重，越需要更多支撑
@export var mass: float = 1.0

## 连接强度：体素与相邻体素之间的连接强度（受力传导能力）
## 应力传播（裂纹扩散）系统使用：每次破坏产生应力，向邻居传播
## 当应力 > 材质的 connection_strength 时，该体素也会断裂（裂纹扩散）
## 值越大，该材质越不容易被"震裂"（如钢铁 > 玻璃 > 泡沫）
## 默认值 10.0，对应应力传播系统默认的 stress_force=15.0
@export var connection_strength: float = 10.0


## 是否透明 (统一判定，供网格生成/着色使用)
func is_transparent() -> bool:
	return trans > 0


# ----------------------------------------------------------------------------
# 材质数组对齐：确保"数组索引 == 材质ID"，体素中存的材质ID可直接作数组索引
# 供 VoxelMeshGenerator / VoxelChunkGenerator 等所有网格生成器统一使用
#
# 统一材质契约（全项目唯一权威）：
#   - 材质ID 0 保留为空/空气：既没有体素也没有材质
#   - 体素存储值 == 材质ID（0 = 空），不存在任何 +1/-1 编码偏移
#   - 对齐后数组索引 == 材质ID，索引 0 恒为 null（空占位）
# ----------------------------------------------------------------------------

## 将任意材质数组转换为"索引 == 材质ID"的对齐数组
## 非 null 材质按其 id 放入对应索引，未填充的位置为 null
## 材质 id <= 0（空）被跳过，保证索引 0 恒为 null = 空占位
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


## 按材质ID获取材质（数组可能未对齐时也能找到），越界/不存在/id<=0(空) 返回 null
static func find_by_id(materials: Array, mat_id: int) -> VoxelMaterial:
	if mat_id <= 0:
		return null
	if mat_id < materials.size() and materials[mat_id] != null:
		return materials[mat_id]
	for mat in materials:
		if mat != null and mat.id == mat_id:
			return mat
	return null


# ----------------------------------------------------------------------------
# 材质→各通道颜色：所有纹理生成（编辑器文件纹理 / 运行时内存纹理）统一采样公式
# 避免编辑器导入与运行时渲染两套实现漂移
# ----------------------------------------------------------------------------

## 反照率颜色 (透明材质：用 1-trans 作为 alpha)
## 设计为静态方法：可对 placeholder 实例(编辑器导入的资源)也安全调用
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


# ----------------------------------------------------------------------------
# UV 采样
# ----------------------------------------------------------------------------

## 材质ID → 纹理采样 U 坐标 (纹素中心对齐，避免落在边界导致取色偏移)
## 所有网格生成器统一使用，保证与 256x1 材质纹理的采样一致
static func uv_for_id(mat_id: int) -> float:
	return (float(mat_id) + 0.5) / 256.0


# ----------------------------------------------------------------------------
# 存档 / 重建
# ----------------------------------------------------------------------------

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
## 返回新的 VoxelMaterial，数据无效时返回 null
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