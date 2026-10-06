@tool
class_name PcgModelGenerator
extends VoxelGenerator

## 适配器：把 PcgModel（整体产出）接到 VoxelGenerator（逐 chunk 供数）上。
##
## 【为什么需要这一层】PcgModel 一次给出整块体素，而框架要的是"按 chunk key 取 32³"。
## 这层把"整体产出"缓存一次，再按 chunk 切片；于是三个算法（L-系统 / 元胞自动机 / WFC）
## 各自只写自己的构建逻辑，缓存与切片代码全项目只此一处。
##
## 【缓存】首次请求任意 chunk 时按 grid_size 构建一次，之后只读。
## 内存 = 一份密集体积（有界模型，尺寸由 VoxelData.grid_size 决定）。
##
## 【用法】与 PcgSdfGenerator 完全同构：
##   一个程序化模型 = 一个【有界 VoxelData】+ 一个【PcgModelGenerator（内嵌一个 PcgModel）】
##                    + 一个【VoxelRenderer 节点】。


## 模型产出（L-系统 / 元胞自动机 / WFC…）。
@export var model: PcgModel

## 精确的模型尺寸：基类只把 grid_size 转成 chunk 级 AABB（会向上取整到 32 的倍数），
## 而构建体积要的是精确尺寸，故在这里单独记一份。
var _grid_size := Vector3i.ZERO
var _volume := PackedInt32Array()
var _built := false


## 覆写：捕获精确尺寸，并让尺寸变化作废旧缓存（基类逻辑照常保留）。
func set_grid_size(voxel_size: Vector3i) -> void:
	super.set_grid_size(voxel_size)
	if _grid_size == voxel_size:
		return
	_grid_size = voxel_size
	_volume = PackedInt32Array()
	_built = false


## LOD0：从缓存体积里切出 32³ 的一块。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	if not _ensure_volume():
		return buf
	var base := VoxelChunk.origin_of(chunk_key)
	for lz in VoxelChunk.CHUNK_SIZE:
		var gz := base.z + lz
		if gz < 0 or gz >= _grid_size.z:
			continue
		for ly in VoxelChunk.CHUNK_SIZE:
			var gy := base.y + ly
			if gy < 0 or gy >= _grid_size.y:
				continue
			var src := gy * _grid_size.x + gz * _grid_size.x * _grid_size.y
			var dst := VoxelChunk.buf_index(0, ly, lz)
			for lx in VoxelChunk.CHUNK_SIZE:
				var gx := base.x + lx
				if gx < 0 or gx >= _grid_size.x:
					continue
				var m := _volume[src + gx]
				if m > 0:
					buf[dst + lx] = m
	return buf


## 粗层 LOD：每个大格取 2^lod 立方内**任一非空**体素的材质（取到即实心）。
## 与 SDF 侧"取格心采样"不同：整体产出的模型常有薄壁，取格心会把它整片采没；
## "格内任一非空"是保守策略——宁可粗层偏实心，也不在远处凭空开洞。
func _generate_chunk_lod(block_key: Vector3i, lod: int) -> PackedInt32Array:
	var grid := VoxelChunkGenerator.LOD_BLOCK_SIZE
	var buf := PackedInt32Array()
	buf.resize(grid * grid * grid)
	if not _ensure_volume():
		return buf
	var cell := 1 << lod
	var base := block_key * (grid * cell)
	for lz in grid:
		for ly in grid:
			for lx in grid:
				var m := _sample_cell(base + Vector3i(lx, ly, lz) * cell, cell)
				if m > 0:
					buf[lx + ly * grid + lz * grid * grid] = m
	return buf


## 惰性构建一次：无模型或无界（grid_size = ZERO）时返回 false（生成全空）。
func _ensure_volume() -> bool:
	if _built:
		return true
	if model == null or _grid_size == Vector3i.ZERO:
		return false
	_volume = model.build(_grid_size)
	_built = true
	return true


## 粗格内任一非空体素的材质（无则 0）。
func _sample_cell(origin: Vector3i, cell: int) -> int:
	for dz in cell:
		var z := origin.z + dz
		if z < 0 or z >= _grid_size.z:
			continue
		for dy in cell:
			var y := origin.y + dy
			if y < 0 or y >= _grid_size.y:
				continue
			var row := y * _grid_size.x + z * _grid_size.x * _grid_size.y
			for dx in cell:
				var x := origin.x + dx
				if x < 0 or x >= _grid_size.x:
					continue
				var m := _volume[row + x]
				if m > 0:
					return m
	return 0
