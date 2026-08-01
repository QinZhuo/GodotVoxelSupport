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


## 是否透明 (统一判定，供网格生成/着色使用)
func is_transparent() -> bool:
	return trans > 0


# ----------------------------------------------------------------------------
# 材质数组对齐：确保"数组索引 == 材质ID"，体素中存的材质ID可直接作数组索引
# 供 VoxelMeshGenerator / VoxelChunkGenerator 等所有网格生成器统一使用
# ----------------------------------------------------------------------------

## 将任意材质数组转换为"索引 == 材质ID"的对齐数组
## 非 null 材质按其 id 放入对应索引，未填充的位置为 null
static func align_by_id(materials: Array) -> Array:
	var aligned: Array = []
	for mat in materials:
		if mat == null:
			continue
		var mat_id: int = mat.id
		while aligned.size() <= mat_id:
			aligned.append(null)
		aligned[mat_id] = mat
	return aligned


## 按材质ID获取材质（数组可能未对齐时也能找到），越界/不存在返回 null
static func find_by_id(materials: Array, mat_id: int) -> VoxelMaterial:
	if mat_id >= 0 and mat_id < materials.size() and materials[mat_id] != null:
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
