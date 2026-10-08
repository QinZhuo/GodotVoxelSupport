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

## 细节层后处理链 —— 在 model.build() 产出整块体素之后、切片之前依次执行。
## 数组顺序即执行顺序（例如"先 PcgWeather 挖出不规则表面，再 PcgSurfaceTint 给
## 暴露面换材质"，凹坑侧面才会被判为暴露面而正常上色）。
## 留空则完全跳过，模型逐体素等同未挂细节层。
@export var details: Array[PcgDetail] = []:
	set(value):
		if details == value:
			return
		details = value
		_invalidate()

## 细节层随机种子。整条链共用一个种子（而不是每个算子各自随机），
## 这样同一 seed 下"换算子顺序"不会各自掷出不同的骰子，便于逐算子比对。
@export var detail_seed: int = 0:
	set(value):
		if detail_seed == value:
			return
		detail_seed = value
		_invalidate()

## 精确的模型尺寸：基类只把 grid_size 转成 chunk 级 AABB（会向上取整到 32 的倍数），
## 而构建体积要的是精确尺寸，故在这里单独记一份。
var _grid_size := Vector3i.ZERO
var _volume := PackedInt32Array()
var _built := false

## 构建互斥：模型覆盖多个 chunk 时，首帧会有多个 worker 线程同时请求不同 chunk，
## 每个都走到 _ensure_volume。无锁则各自 build 一遍（N× 白算），且 PcgWfcOverlap._learn()
## 会写实例成员 _patterns/_allow —— 并发即正确性 bug，不只是浪费。
var _build_mutex := Mutex.new()


## 丢弃缓存体积，强制下次请求时重建。details / detail_seed 改动后必须调用，
## 否则 @tool 场景里调了细节层参数却看不到任何变化。
## 不取锁（与 set_grid_size 同理：setter 由主线程调用，不能阻塞在途 worker）。
func _invalidate() -> void:
	_volume = PackedInt32Array()
	_built = false


## 覆写：捕获精确尺寸，并让尺寸变化作废旧缓存（基类逻辑照常保留）。
func set_grid_size(voxel_size: Vector3i) -> void:
	super.set_grid_size(voxel_size)
	if _grid_size == voxel_size:
		return
	_grid_size = voxel_size
	_invalidate()


## LOD0：从缓存体积里切出 32³ 的一块。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	if not _ensure_volume():
		return buf
	var gs := _grid_size
	var vol := _volume
	if vol.is_empty():
		return buf  # 源产出了空体积（例如空链 + 无手绘体素）：直接给全空，别去下标越界
	var base := VoxelChunk.origin_of(chunk_key)
	for lz in VoxelChunk.CHUNK_SIZE:
		var gz := base.z + lz
		if gz < 0 or gz >= gs.z:
			continue
		for ly in VoxelChunk.CHUNK_SIZE:
			var gy := base.y + ly
			if gy < 0 or gy >= gs.y:
				continue
			var src := gy * gs.x + gz * gs.x * gs.y
			var dst := VoxelChunk.buf_index(0, ly, lz)
			for lx in VoxelChunk.CHUNK_SIZE:
				var gx := base.x + lx
				if gx < 0 or gx >= gs.x:
					continue
				var m := vol[src + gx]
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
	var gs := _grid_size
	var vol := _volume
	if vol.is_empty():
		return buf
	for lz in grid:
		for ly in grid:
			for lx in grid:
				var m := _sample_cell(vol, gs, base + Vector3i(lx, ly, lz) * cell, cell)
				if m > 0:
					buf[lx + ly * grid + lz * grid * grid] = m
	return buf


## 有产出源吗？无源时 _ensure_volume 直接返回 false（生成全空）。
##
## 子类覆写点：换一个体积来源只需覆写本函数 + _build_volume()，
## 缓存 / 切片 / LOD 逻辑原样复用，全项目仍只有一份。
func _has_source() -> bool:
	return model != null


## 产出整块体积。
##
## 【后处理链】model.build() 之后、提交缓存之前，按 details 数组顺序跑一遍细节层。
## 此时 vol 是 build() 刚返回的新数组（引用计数为 1），**原地改写不会触发写时复制**；
## 也依赖"细节层只改体素、不改 grid_size"这一契约（见 PcgDetail）。
##
## 【并发契约】**本函数在 worker 线程内被调用**：只读，可重入，不改本对象的可观测状态。
## 子类实现（如 QVoxObjectGenerator 跑修改器链）必须守同一条规矩。
func _build_volume(grid_size: Vector3i) -> PackedInt32Array:
	if model == null:
		return PackedInt32Array()
	var vol := model.build(grid_size)
	for d in details:
		if d != null:
			d.apply(vol, grid_size, detail_seed)
	return vol


## 惰性构建一次：无源或无界（grid_size = ZERO）时返回 false（生成全空）。
##
## 【并发】免锁快路径 + 锁内构建 + 提交前校验尺寸。多处要点：
##   ① 快路径先查 _built：稳态下每个 chunk 都走这条路，不该付锁开销；
##      _volume 在 _built = true 之前写毕，故读到 true 即可放心读 _volume。
##   ② 锁内再查一次 _built：等锁期间别人可能已经建好（这就是"只 build 一次"的实现）。
##   ③ 提交前校验 _grid_size 未变：set_grid_size() 由主线程调用且**不能取锁**
##      （否则主线程被在途构建阻塞），故用"构建完比对"来丢弃过期结果，而不是让 setter 抢锁。
##   ④ **空体积也要提交 _built**：否则每个 chunk 都会重跑一次 _build_volume（链求值可能是
##      整块体积的开销）。空体积由切片侧用 is_empty() 早退拦下，不再走下标访问。
func _ensure_volume() -> bool:
	if _built:
		return true
	if not _has_source() or _grid_size == Vector3i.ZERO:
		return false
	_build_mutex.lock()
	if not _built:
		var gs := _grid_size
		var vol := _build_volume(gs)
		if gs == _grid_size:
			_volume = vol
			_built = true
	_build_mutex.unlock()
	return _built


## 粗格内任一非空体素的材质（无则 0）。volume / grid_size 由调用方捕获传入
## （而不是读成员）：PackedInt32Array 是写时复制，局部句柄即使期间被重建也安全，
## 避免"循环中途换手"读到另一尺寸的数组。
func _sample_cell(volume: PackedInt32Array, grid_size: Vector3i, origin: Vector3i, cell: int) -> int:
	for dz in cell:
		var z := origin.z + dz
		if z < 0 or z >= grid_size.z:
			continue
		for dy in cell:
			var y := origin.y + dy
			if y < 0 or y >= grid_size.y:
				continue
			var row := y * grid_size.x + z * grid_size.x * grid_size.y
			for dx in cell:
				var x := origin.x + dx
				if x < 0 or x >= grid_size.x:
					continue
				var m := volume[row + x]
				if m > 0:
					return m
	return 0
