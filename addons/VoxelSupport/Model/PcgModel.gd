@tool
@abstract
class_name PcgModel
extends Resource

## 整体模型产出抽象 —— 与 Sdf 的"逐点函数"平级，但回答的是另一个问题。
##
## 【为什么需要两个基类】SDF 的表达方式是 `sample(p) → 距离`（适合"由简单件组合出的实体"）；
## 而 L-系统 / 元胞自动机 / WFC 这类算法的产出方式是**全局迭代**——先生成一整块体素，
## 再切成 chunk，无法写成逐点函数。于是各有一个基类：
##     Sdf      —— 逐点采样（配 PcgSdfGenerator）    —— 局部、可无限延伸
##     PcgModel —— 整体产出（配 PcgModelGenerator）  —— 全局、天然有界
##
## 【契约】`build(grid_size)` 返回长度 = x*y*z 的密集 PackedInt32Array，
## 值 = 材质ID（0 = 空），下标 = `index_of()`（x 连续，再 y，再 z）。
## 必须**确定性**：同 grid_size 恒得同一结果（用固定种子，不要依赖全局随机）。
##
## 【有界】grid_size 来自 VoxelData.grid_size（与 SDF 模型同一套有界语义），
## 实现只在给定尺寸内绘制，越界写入由 set_voxel 自动忽略。


## 生成整块体素。子类只需关心"怎么画"，不必关心 chunk 切分与缓存。
@abstract
func build(grid_size: Vector3i) -> PackedInt32Array


## 这个算子能不能作为修改器链的一环（默认能）。
##
## 【为什么要给它一个显式否定】链是**线性**的：每一步只看上一步累积出的结果。
## 有两类算子做不到 —— 这不是"还没实现"，而是"不该进链"，强行接进来只会让链的契约长出一个
## 例外，而例外的数量就是自动插入降级点、自动重排这些能力失效的起点：
##   · 需要**全局信息**的（`PcgWfcOverlap`）：重叠式 WFC 要在整块体积上按重叠约束迭代收敛，
##     还得在内部带一份可变学习缓存（进链就必须给它套互斥锁，而且语义与"它排第几"强耦合）；
##   · **非体积语义**的（`PcgScatter`）：它按世界坐标把物件摆进场景，既不产体素也不吃体素，
##     属于链**之外**的摆放阶段，天生不是链条目（连本类都不是，故无此方法）。
## 编辑器据此把这类算子从"可加入链"的候选里灰掉，而不是让用户拖进去再报错。
func chainable() -> bool:
	return true


# ----------------------------------------------------------------------------
# 子类共用工具（静态、越界安全，避免每个算法各抄一遍下标公式）
# ----------------------------------------------------------------------------

## 三维下标 → 一维下标（布局：x 连续，再 y，再 z）。
static func index_of(x: int, y: int, z: int, grid_size: Vector3i) -> int:
	return x + y * grid_size.x + z * grid_size.x * grid_size.y


## 一维下标 → 三维下标（index_of 的逆）。**布局公式只此一处**：凡是要"反过来扫一遍体积"的
## 消费方（`.vox` 导出、缩略图、统计）都调它，而不是各自再抄一遍取模 —— 抄错一格不会报错，
## 只会让导出的模型在某一个轴上整体错位。
##
## 越界（负数 / 空盒 / 下标超出体积）返回 Vector3i.ZERO：调用方拿到的是"安全但无意义"的值，
## 而不是一个会污染下游数据的乱码坐标。
static func pos_of(index: int, grid_size: Vector3i) -> Vector3i:
	if index < 0 or grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		return Vector3i.ZERO
	if index >= grid_size.x * grid_size.y * grid_size.z:
		return Vector3i.ZERO
	@warning_ignore("integer_division")
	var x := index % grid_size.x
	@warning_ignore("integer_division")
	var y := (index / grid_size.x) % grid_size.y
	@warning_ignore("integer_division")
	var z := index / (grid_size.x * grid_size.y)
	return Vector3i(x, y, z)


## 全空体积（长度已对齐 grid_size）——所有实现的绘制起点。
static func empty_volume(grid_size: Vector3i) -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(maxi(grid_size.x * grid_size.y * grid_size.z, 0))
	return v


## 越界安全的单格写入。子类绘制时不必自己夹取边界。
static func set_voxel(volume: PackedInt32Array, x: int, y: int, z: int,
		grid_size: Vector3i, material_id: int) -> void:
	if x < 0 or y < 0 or z < 0 or x >= grid_size.x or y >= grid_size.y or z >= grid_size.z:
		return
	volume[index_of(x, y, z, grid_size)] = material_id
