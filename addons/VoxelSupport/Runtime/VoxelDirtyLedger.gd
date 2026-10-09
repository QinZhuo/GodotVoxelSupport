class_name VoxelDirtyLedger
extends RefCounted

## 体素数据层"脏账本"：把原先散落的 5 本账收拢成**一份带位标记的账本**。
##
## 收拢前各自独立维护（新增一处脏标记很容易忘记清另一处 → 幽灵状态）：
##   写盘账 / 网格重建账 / 粗层失效账 / 粗层回退账 / 粗层脏区域账
##
## 现结构：
##   _flags[level][key] -> 位标记（"为何脏"）
##     level 0   = LOD0 chunk 空间，key = chunk key        （标记 PERSIST / MESH）
##     level >=1 = 粗层 block 空间，key = block key        （标记 LOD_MESH / COARSE_MODIFIED）
##   _region[level][block_key] -> [gmin, gmax]（块内大格坐标，含端点；level >=1）
##
## 统一的好处：标记 / 取走 / 擦除 / 平移 / 清空都只经过这里，"漏清一处"不再可能散落在
## QVoxelSource 的十几个函数里。区域账不是布尔（带 [min,max] 数据）故单独一张表。
##
## 注意 level 0 的 key 空间是 chunk key 与粗层 block key **共用**的：_accept_chunk_buffer
## 对 lod>=1 的块回填也会往 level 0 打 MESH 标记，渲染器 is_chunk_mesh_dirty 读的就是它。
## 该约定是历史行为，收拢时原样保留。

# ---------------------------------------------------------------------------
# 位标记
# ---------------------------------------------------------------------------
## 需写盘 / 随资源持久化（level 0）
const PERSIST := 1 << 0
## 需重建网格（level 0）
const MESH := 1 << 1
## 粗层 block 网格失效待重建（level >=1）
const LOD_MESH := 1 << 2
## 粗层 block 被编辑影响，需从 LOD0 降采样回退（level >=1）
const COARSE_MODIFIED := 1 << 3

## 脏大格区域并集 [min, max] 的哨兵端值：min 起点取 +∞、max 起点取 -∞，首次 mini/maxi 即被真实值取代。
## 只具名两个 Vector3i（值类型，共享安全）；累积数组仍须每次现造（见 mark_region），
## 否则 layer.get 缺省返回同一份数组引用，首次写入就会污染这个"空初值"。
const REGION_MIN := Vector3i(999999, 999999, 999999)
const REGION_MAX := Vector3i(-1, -1, -1)

## _flags[level][key] -> 位标记
var _flags: Array[Dictionary] = []
## _region[level][block_key] -> [gmin, gmax]
var _region: Array[Dictionary] = []


## 取"分层字典数组"的第 level 层（必要时补足到该层）。全项目唯一维护这类数组的地方：
## 各层各自一张 {key: value} 表；越界即补空层，避免每处手写 while-append（易漏、易越界）。
static func _layer(layers: Array[Dictionary], level: int) -> Dictionary:
	while layers.size() <= level:
		layers.append({})
	return layers[level]


## 预建到 level 层（无副作用，便于调用方先确保层级存在）
func ensure_level(level: int) -> void:
	_layer(_flags, level)


## 清 (level, key) 的一个标记位；条目归零即移除（不变式：账本里不存在 0 值条目）
static func _unset(layer: Dictionary, key: Vector3i, flag: int) -> void:
	var v := int(layer.get(key, 0)) & ~flag
	if v == 0:
		layer.erase(key)
	else:
		layer[key] = v


# ---------------------------------------------------------------------------
# 写
# ---------------------------------------------------------------------------
## 给 (level, key) 叠加标记位（唯一写入口）
func mark(level: int, key: Vector3i, flags: int) -> void:
	var layer := _layer(_flags, level)
	layer[key] = int(layer.get(key, 0)) | flags


## 批量叠加标记位（调用方已备好 key 列表时用，避免逐 key 重复取层）
func mark_many(level: int, keys: Array, flags: int) -> void:
	var layer := _layer(_flags, level)
	for key: Vector3i in keys:
		layer[key] = int(layer.get(key, 0)) | flags


## 记录 block 的脏大格区域并集（gmin/gmax 为 block 内大格坐标、含端点，已由调用方 clamp）
func mark_region(level: int, key: Vector3i, gmin: Vector3i, gmax: Vector3i) -> void:
	var layer := _layer(_region, level)
	var r: Array = layer.get(key, [REGION_MIN, REGION_MAX])
	r[0] = Vector3i(mini(r[0].x, gmin.x), mini(r[0].y, gmin.y), mini(r[0].z, gmin.z))
	r[1] = Vector3i(maxi(r[1].x, gmax.x), maxi(r[1].y, gmax.y), maxi(r[1].z, gmax.z))
	layer[key] = r


# ---------------------------------------------------------------------------
# 读
# ---------------------------------------------------------------------------
## (level, key) 是否带某标记
func has(level: int, key: Vector3i, flag: int) -> bool:
	return level < _flags.size() and (int(_flags[level].get(key, 0)) & flag) != 0


## 该层带某标记的 key 数（不构造数组）
func count(level: int, flag: int) -> int:
	if level >= _flags.size():
		return 0
	var n := 0
	var layer := _flags[level]
	for k in layer:
		if int(layer[k]) & flag:
			n += 1
	return n


## 该层是否有任一 key 带某标记
func has_any(level: int, flag: int) -> bool:
	if level >= _flags.size():
		return false
	var layer := _flags[level]
	for k in layer:
		if int(layer[k]) & flag:
			return true
	return false


## 从 from_level 起的任一层是否有 key 带某标记（跨层扫描，如"有没有待重建的粗层块"）
func has_any_from(from_level: int, flag: int) -> bool:
	for level in range(maxi(from_level, 0), _flags.size()):
		if has_any(level, flag):
			return true
	return false


## 该层 key 列表（flag 非 0 时只取带该标记的）；不修改账本
func keys(level: int, flag: int = 0) -> Array:
	var out: Array = []
	if level >= _flags.size():
		return out
	var layer := _flags[level]
	for k in layer:
		if flag == 0 or (int(layer[k]) & flag) != 0:
			out.append(k)
	return out


## 取并清空指定 block 的脏大格区域（渲染器增量降采样消费）
func take_region(level: int, key: Vector3i) -> Array:
	if level >= _region.size():
		return []
	var layer: Dictionary = _region[level]
	var r: Array = layer.get(key, [])
	layer.erase(key)
	return r


## 擦除指定 block 的脏大格区域（该块数据已消失时用，避免账本随探索无界增长）
func erase_region(level: int, key: Vector3i) -> void:
	if level < _region.size():
		_region[level].erase(key)


## 清空所有层级的脏大格区域（世界级重置：clear / 载荷重建时调用）
func clear_regions() -> void:
	for d in _region:
		d.clear()


# ---------------------------------------------------------------------------
# 清
# ---------------------------------------------------------------------------
## 取走该层带某标记的全部 key，并清掉该标记（其余标记保留；条目归零即移除）
func take(level: int, flag: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if level >= _flags.size():
		return out
	var layer := _flags[level]
	for k in layer.keys():
		if int(layer[k]) & flag:
			out.append(k)
			_unset(layer, k, flag)
	return out


## 清 (level, key) 的某标记（其余标记保留）
func clear_flag(level: int, key: Vector3i, flag: int) -> void:
	if level < _flags.size():
		_unset(_flags[level], key, flag)


## 清该层所有 key 的某标记
func clear_flags(level: int, flag: int) -> void:
	if level >= _flags.size():
		return
	var layer := _flags[level]
	for k in layer.keys():
		_unset(layer, k, flag)


## 清所有层级所有 key 的某标记
func clear_flags_all(flag: int) -> void:
	for level in _flags.size():
		clear_flags(level, flag)


## 擦除 (level, key) 的全部标记（该处数据已消失时用）
func erase(level: int, key: Vector3i) -> void:
	if level < _flags.size():
		_flags[level].erase(key)


## 全清（世界级重置：clear / 载荷重建）
func clear_all() -> void:
	_flags.clear()
	_region.clear()


## 原点重定位：账本 key 整体平移（各层一起挪，避免只挪一半留下错位账本）
func shift(offset: Vector3i) -> void:
	if offset == Vector3i.ZERO:
		return
	for i in _flags.size():
		_flags[i] = VoxelChunk.shift_key_dict(_flags[i], offset)
	for i in _region.size():
		_region[i] = VoxelChunk.shift_key_dict(_region[i], offset)
