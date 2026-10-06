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


# ----------------------------------------------------------------------------
# 子类共用工具（静态、越界安全，避免每个算法各抄一遍下标公式）
# ----------------------------------------------------------------------------

## 三维下标 → 一维下标（布局：x 连续，再 y，再 z）。
static func index_of(x: int, y: int, z: int, grid_size: Vector3i) -> int:
	return x + y * grid_size.x + z * grid_size.x * grid_size.y


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
