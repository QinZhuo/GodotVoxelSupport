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
# 整块体积光栅化（有界模型：一次要一整块，而不是按需逐 chunk）
# ----------------------------------------------------------------------------
# 【为什么放在契约类上】"把逐 chunk 输出拼成一整块"对任何生成器都成立（SDF 生成器、
# PcgModelGenerator、未来新增的），与具体算法无关 —— 该和 generate() 待在一起。
# 早先它被单列成一个 QVoxelRasterizer 类，但那个类里没有一行自己的算法，只是转发；
# 于是"光栅化"名下有两个实现（真正调优过的逐体素采样在 PcgSdfGenerator 里），
# 正是双份维护的开端。合并后职责各一份：逐点算法在 PcgSdfGenerator，拼接在这里。

## 把本生成器在 [0, grid_size) 上的全部输出拼成一整块密集体积。
## 值 = 材质ID（0 = 空），下标布局 = PcgModel.index_of。
##
## 【为什么先调 set_grid_size】PcgModelGenerator 依赖它做边界夹取（有界模型的既有约定）；
## 无限世界的生成器（恒可生成）忽略该限制，行为不变。
func to_volume(grid_size: Vector3i) -> PackedInt32Array:
	var vol := PackedInt32Array()
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		return vol
	set_grid_size(grid_size)
	vol.resize(grid_size.x * grid_size.y * grid_size.z)
	# 遍历覆盖该体积的全部 chunk。有界模型的体素坐标从原点 0 起算，故 chunk 键恒为非负。
	var cs := VoxelChunk.CHUNK_SIZE
	var c1 := Vector3i(
			(grid_size.x - 1) / cs,
			(grid_size.y - 1) / cs,
			(grid_size.z - 1) / cs)
	for cz in range(0, c1.z + 1):
		for cy in range(0, c1.y + 1):
			for cx in range(0, c1.x + 1):
				_blit_chunk(Vector3i(cx, cy, cz), vol, grid_size)
	return vol


## 把一个 chunk 的输出散写进整块体积（越界部分丢弃 —— 体积尺寸未必是 chunk 的整数倍）。
func _blit_chunk(ck: Vector3i, vol: PackedInt32Array, grid_size: Vector3i) -> void:
	var buf := generate(ck, 0)
	if buf.is_empty():
		return
	var origin := VoxelChunk.origin_of(ck)
	var cs := VoxelChunk.CHUNK_SIZE
	# 该 chunk 落在体积内的局部区间（先算区间，避免逐格判越界）。
	var x0 := maxi(0, -origin.x)
	var y0 := maxi(0, -origin.y)
	var z0 := maxi(0, -origin.z)
	var x1 := mini(cs, grid_size.x - origin.x)
	var y1 := mini(cs, grid_size.y - origin.y)
	var z1 := mini(cs, grid_size.z - origin.z)
	if x0 >= x1 or y0 >= y1 or z0 >= z1:
		return
	for lz in range(z0, z1):
		for ly in range(y0, y1):
			var src := VoxelChunk.buf_index(x0, ly, lz)
			var dst := PcgModel.index_of(origin.x + x0, origin.y + ly, origin.z + lz, grid_size)
			for lx in range(x0, x1):
				vol[dst] = buf[src]
				src += 1
				dst += 1


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
