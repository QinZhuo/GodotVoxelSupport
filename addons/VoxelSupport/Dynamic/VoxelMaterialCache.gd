## 材质缓存：把原先散落在 VoxelRenderer / VoxelDestructible 里的四份材质派生数据收成一份。
## 权威始终是 QVoxelSource.materials（材质表），本类只做派生与惰性重建：
##   派生 1  snapshot     —— 权威表的深拷贝，供子线程只读（避免跨线程访问 Resource）
##   派生 2  surfaces     —— 运行时 Material 对象数组（渲染用，索引 0/1 对应两个表面）
##   派生 3  aligned[层]  —— 各 LOD 层"按材质 ID 对齐"的数组（生成器要求 索引 == 材质ID）
## 【为什么需要它】旧实现这几份各自散在 VoxelRenderer 里、由 5 处清空点手工维护，
## 漏清一份就表现为"材质改了但颜色/透明度不更新"——见 VoxelRenderer 里
## _clear_lod_block_state 的事故注释（"旧材质对齐结果会残留，会让粗层用错材质"）。
## VoxelDestructible 还另有一份同语义的运行时材质缓存。现在失效只有 invalidate()
## 一个入口，不存在"记得清这一份、忘了那一份"。
## 【失效的两条通道】二者互补，缺一不可：
##   1) 源引用比对（自动）：调用方换了 data.materials（新数组/新材质对象）时自动重建；
##   2) invalidate()（显式）：材质对象**属性**变了（regenerate_materials 的语义）时，
##      数组内容不变、引用比对探不到，必须由调用方显式作废。
class_name VoxelMaterialCache
extends RefCounted

## 权威表的深拷贝缓存（作废后或源引用变化时下次 snapshot() 重建）
var _snapshot: Array = []
var _snapshot_dirty: bool = true
var _snapshot_src: Array = []
## 运行时 Material 对象数组（空/首项为 null/源引用变化时下次 surfaces() 重建）
var _surfaces: Array = []
var _surfaces_src: Array = []
## 各 LOD 层的对齐数组（该层为空时下次 aligned() 重建）
var _aligned: Array[Array] = []


## 材质表内容变化后调用（regenerate_materials / 切换 data）：三份派生全部作废
## 用"换新数组"而非就地 clear()：surfaces() 的返回值可能正被调用方（渲染/掉落块）持有，
## 就地清空会连带清掉他们手上的那份；换新数组则旧引用仍然完整、新取才拿到新派生。
func invalidate() -> void:
	_snapshot_dirty = true
	_surfaces = []
	invalidate_aligned()


## 只作废各层对齐数组（block 账本整表清理时用；快照与运行时材质仍然有效）
func invalidate_aligned() -> void:
	for i in _aligned.size():
		_aligned[i] = []


## 权威表的深拷贝（供子线程只读）。惰性：仅在作废后或源引用变化时重建。
func snapshot(src: Array) -> Array:
	if _snapshot_dirty or _snapshot_src != src:
		_snapshot = src.duplicate(true)
		_snapshot_src = src
		_snapshot_dirty = false
	return _snapshot


## 运行时 Material 对象数组（渲染用）。惰性。
func surfaces(src: Array) -> Array:
	if _surfaces.is_empty() or _surfaces[0] == null or _surfaces_src != src:
		_surfaces = VoxelMeshGenerator.generate_textured_materials_runtime(src)
		_surfaces_src = src
	return _surfaces


## 某 LOD 层的对齐数组。惰性：该层为空（含被 invalidate 清空）时重建。
func aligned(src: Array, level: int) -> Array:
	_ensure_level(level)
	if _aligned[level].is_empty():
		_rebuild_level(src, level)
	return _aligned[level]


## 强制重建某层的对齐数组（派发任务前刷新，保证 worker 拿到最新材质）。
func rebuild_aligned(src: Array, level: int) -> Array:
	_ensure_level(level)
	_rebuild_level(src, level)
	return _aligned[level]


## 同步 LOD 层数（层数增减时裁剪/补齐；调用方在改层数后调用一次即可）
func set_level_count(n: int) -> void:
	while _aligned.size() > n:
		_aligned.pop_back()
	if n > 0:
		_ensure_level(n - 1)


func _ensure_level(level: int) -> void:
	while _aligned.size() <= level:
		_aligned.append([])


func _rebuild_level(src: Array, level: int) -> void:
	_aligned[level].assign(VoxelMaterial.align_by_id(snapshot(src)))
