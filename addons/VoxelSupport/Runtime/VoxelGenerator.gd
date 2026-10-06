@tool
@abstract
class_name VoxelGenerator
extends Resource

## 体素数据生成器抽象 —— 与 VoxelStream 并列：一个"造数据"，一个"存数据"。
##
## 【职责边界】只定义"按 key 造出体素数据"的通用契约，服务所有数据源；具体算法交给子类
## （如程序化地形 PcgTerrainGenerator、SDF 模型 PcgSdfGenerator）。
##
## 【为什么与流分开】无限世界的"读取"其实是"生成"，它没有任何存储。早先把它做成
## VoxelStream 的子类（VoxelProceduralStream），代价是 has_chunk 一个名字要同时表示
## "已存在流中"和"属于可生成范围"两种含义，调用方只能靠 `is 类型` 逐处分支去猜哪个
## 含义成立。拆开后两边各只有一个含义：
##     VoxelStream.has_chunk          = 已在流中（存储事实）
##     VoxelGenerator.is_in_generation_bounds = 可以生成（生成能力）
## 谁先取、何时异步、结果怎么回填，全部由 VoxelData 一处编排（见 VoxelAsyncLoader）。
##
## 【生成器不做的事】不碰 I/O、不持有"在途 / 就绪"状态、不知道有没有人存过 ——
## 它只是一对纯函数（加一块"可生成范围"的几何信息）。
##
## 【确定性要求】必须对同一 key 返回相同数据（噪声用 key 派生种子）。否则 origin shift
## 平移 key 后地形不连续，且同一 chunk 重复生成会得到不同结果。
##
## 【两种用法同一套接口】
##   无限世界：不设范围（恒 true）→ 任意 chunk 可生成（如噪声地形）。
##   有界模型：set_grid_size / set_chunk_bounds 限定范围（如建筑蓝图、程序化模型），
##             配合 VoxelData.grid_size，一个模型就是一"个有界生成器 + 一个 VoxelData"。


## @abstract 按 chunk key 生成 32³ chunk 缓冲（值 = 材质ID，0 = 空）。
@abstract
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array


## @abstract 按 block key 生成粗层 LOD block 数据（LOD_GRID³ 大格，值 = 材质ID，0 = 空，
## 每格 = 2^lod 体素）。远处粗层直接以粗粒度生成，无需先加载全部 LOD0 chunk 再降采样。
## lod=1：32³ 大格覆盖 64³ 体素；lod=i：每格 2^i 体素。
@abstract
func _generate_chunk_lod(block_key: Vector3i, lod: int) -> PackedInt32Array


## 统一生成入口：按 lod 分流到上面两个虚函数（lod=0 → chunk，>=1 → 粗层 block）。
## 供编排方（VoxelAsyncLoader）在后台线程调用。
func generate(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	return _generate_chunk(chunk_key) if lod == 0 else _generate_chunk_lod(chunk_key, lod)


# ----------------------------------------------------------------------------
# 可生成范围
# ----------------------------------------------------------------------------
# 渲染器距离扫描会高频调用（view_distance 内逐 chunk），必须 O(1) 且零内存分配。
# 两层判定，后者优先：
#   1) 精确集合 _chunk_set：稀疏 / 不规则覆盖（如建筑内部空心，只有墙与房间所在 chunk）。
#      空 = 本层不启用。集合已含出界雨棚/屋檐等元素，故它启用时 AABB 不参与判定
#      —— 按 grid_size 推导的 AABB 会漏掉出界元素。
#   2) AABB（_bounds_active，chunk 坐标 min/max）：矩形世界（如整张地图），3 轴整数比较。
# 两者都不启用 = 无限世界：恒 true（任何 chunk 可生成）。

var _bounds_min: Vector3i = Vector3i.ZERO
var _bounds_max: Vector3i = Vector3i.ZERO
var _bounds_active: bool = false
var _chunk_set: Dictionary = {}


## 按体素尺寸设定矩形覆盖范围（chunk 坐标 0 到 size-1 所在 chunk）。
## 与 VoxelData.grid_size 配合：VoxelData 设置 generator 时自动调用，调用方无需手动。
## size = ZERO 视为无限世界（保持恒 true）。
func set_grid_size(voxel_size: Vector3i) -> void:
	if voxel_size == Vector3i.ZERO:
		_bounds_active = false
		return
	_bounds_min = Vector3i.ZERO
	_bounds_max = VoxelChunk.chunk_of(voxel_size - Vector3i.ONE)
	_bounds_active = true


## 设定有限 chunk 覆盖范围（有限模板生成器，如建筑蓝图）。
func set_chunk_bounds(keys: Array[Vector3i]) -> void:
	_chunk_set.clear()
	for ck in keys:
		_chunk_set[ck] = true


## 该 chunk（lod=0）或粗层 block（lod>=1）是否属于本生成器可生成的范围。
##
## 【lod 语义必须分清】lod=0 时 key 是 chunk 坐标；lod>=1 时 key 是 block 坐标
## （= chunk_key >> lod），数值比 chunk 小得多，**不能**直接按 chunk 语义比较——那会把
## "覆盖到范围外的 block"误判为可生成（如 chunk 边界 [0,7] 时 block key 4 覆盖 chunk 8..11，
## 却 4<=7 通过）。故 lod>=1 先把 block 展开成它覆盖的 LOD0 chunk 范围，再判"与可生成范围
## 是否有交集"——边缘 block 必然重叠，重叠就该生成（否则地图边缘的粗层缺格）。
func is_in_generation_bounds(key: Vector3i, lod: int = 0) -> bool:
	if lod >= 1:
		return _block_overlaps_bounds(key, lod)
	if not _chunk_set.is_empty():
		return _chunk_set.has(key)
	if _bounds_active:
		return key.x >= _bounds_min.x and key.x <= _bounds_max.x \
			and key.y >= _bounds_min.y and key.y <= _bounds_max.y \
			and key.z >= _bounds_min.z and key.z <= _bounds_max.z
	return true


## 粗层 block 覆盖的 LOD0 chunk 范围与可生成范围是否有交集。
func _block_overlaps_bounds(block_key: Vector3i, lod: int) -> bool:
	var span := 1 << lod
	var lo := block_key * span
	var hi := lo + Vector3i(span - 1, span - 1, span - 1)
	if not _chunk_set.is_empty():
		# 稀疏集合（有限模板）：任一覆盖 chunk 命中即可生成
		for ck in VoxelChunk.lod_covered_chunks(block_key, lod):
			if _chunk_set.has(ck):
				return true
		return false
	if _bounds_active:
		return lo.x <= _bounds_max.x and hi.x >= _bounds_min.x \
			and lo.y <= _bounds_max.y and hi.y >= _bounds_min.y \
			and lo.z <= _bounds_max.z and hi.z >= _bounds_min.z
	return true


## origin shift 时同步平移范围限制（chunk 坐标随数据基准移动）。
func shift_bounds(offset: Vector3i) -> void:
	if _bounds_active:
		_bounds_min += offset
		_bounds_max += offset


## 渲染器距离扫描的垂直半跨度（chunk 数）：dy ∈ [-span, span]。
## 无限世界（地表以下全实心 / 以上全空）默认 ±1 层足够；
## 有限世界（AABB 生效）按 grid_size 推导的世界高度覆盖全部层。
func get_vertical_half_span() -> int:
	if _bounds_active:
		return maxi(absi(_bounds_max.y - _bounds_min.y), 1)
	return 1
