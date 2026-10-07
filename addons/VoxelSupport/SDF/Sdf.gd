@tool
@abstract
class_name Sdf
extends Resource

## SDF（有符号距离场）节点基类 —— 体素模型的几何描述（建模原语）。
##
## 每个 SDF 都是一个纯函数：`sample(p) → Vector2(有符号距离, 材质ID)`。
##   距离 < 0：点在实体内部（会被光栅化成体素）
##   距离 > 0：点在实体外部
##   距离 = 0：表面
##
## 【为什么用 SDF 造模型】分辨率无关——改体素尺度只改采样密度，不改形状定义；
## 并 / 交 / 差 与平滑并（smin）是一等公民，天然适合"岩石 / 树 / 建筑 / 道具"
## 这类由简单件组合出来的模型。组合成树（Resource + @export）后可在 inspector
## 里直接编辑，无需写代码；同一棵树喂给不同分辨率得到同一形状。
##
## 【采样坐标】是**体素坐标**（非世界坐标）：SDF 参数与体素尺寸同单位。
## 世界尺度由 VoxelRenderer.voxel_scale 负责，几何定义与渲染尺度解耦。
## 采样点由 PcgSdfGenerator 按 chunk 逐格心喂入。
##
## 【材质传递】组合算子按"离表面更近"的分支传材质（见 pick / pick_far）：
## 并 / 平滑并 / 差集取更近者（差集恒取 a），交集取约束更紧（距离更大）者，
## 使各部件在融合处仍能保住自己的材质。


## 采样：返回 (有符号距离, 材质ID)。距离 < 0 表示实心。
@abstract
func sample(p: Vector3) -> Vector2


## 实体所在的大致包围盒（体素单位）。默认无界。
## 仅作上层推导 grid_size 的参考——真正的裁剪由 VoxelData.grid_size → set_grid_size 负责。
func bounds() -> AABB:
	return unbounded()


# ----------------------------------------------------------------------------
# 组合算子共用工具（全部静态、零分配，采样热路径可高频调用）
# ----------------------------------------------------------------------------

## 无界哨兵：size 分量为负，仅用于 bounds() 表达能力，不参与几何计算。
static func unbounded() -> AABB:
	return AABB(Vector3.ZERO, Vector3(-1.0, -1.0, -1.0))


## 该包围盒是否代表"无界"。
static func is_unbounded(b: AABB) -> bool:
	return b.size.x < 0.0


## "远在外部"的兜底采样值：组合算子的入参端口（a / b）未填（inspector 留空）时使用。
static func far() -> Vector2:
	return Vector2(1e20, 0.0)


## 采样兜底：字段为空时返回 far()，使组合算子在入参端口留空时仍可正常工作。
static func sample_field(field: Sdf, p: Vector3) -> Vector2:
	return field.sample(p) if field != null else far()


## 取更近者（距离更小），材质随之一并传递。
static func pick(a: Vector2, b: Vector2) -> Vector2:
	return a if a.x <= b.x else b


## 取更远者（距离更大 = 约束更紧），材质随之一并传递。
static func pick_far(a: Vector2, b: Vector2) -> Vector2:
	return a if a.x >= b.x else b


## 两个包围盒的并（任一为无界 → 结果无界）。
static func merged_bounds(a: AABB, b: AABB) -> AABB:
	if is_unbounded(a) or is_unbounded(b):
		return unbounded()
	return a.merge(b)


## 两个包围盒的交（任一为无界 → 返回另一个 = 更紧的那个）。
static func intersected_bounds(a: AABB, b: AABB) -> AABB:
	if is_unbounded(a):
		return b
	if is_unbounded(b):
		return a
	return a.intersection(b)
