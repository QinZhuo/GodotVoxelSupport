## 材质缓存：把 VoxelRenderer / VoxelDestructible 需要的四份材质派生数据收成一份。
## 权威始终是 QVoxelSource.materials（材质表），本类只做派生与惰性重建：
##   派生 1  snapshot     —— 权威表的深拷贝，供子线程只读（避免跨线程访问 Resource）
##   派生 2  surfaces     —— 运行时 Material 对象数组（渲染用，索引 0/1 对应两个表面）
##   派生 3  aligned[层]  —— 各 LOD 层"按材质 ID 对齐"的数组（生成器要求 索引 == 材质ID）
## 【为什么需要它】这几份派生数据若散在 VoxelRenderer 里、由多个清空点手工维护，
## 漏清一份就表现为"材质改了但颜色/透明度不更新"，粗层会继续用旧的对齐结果。
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


## 与 aligned() 同值，但语义上**明确"只读共享、不拷贝"**：返回的就是内部缓存那一份数组对象。
##
## 契约（调用方必须遵守，否则是本类无法防御的数据竞态）：
##   · **只读**。绝不 append / remove_at / assign / 排序返回的数组；
##   · **不得跨 invalidate_aligned() / rebuild_aligned() 持有**并继续读 —— 这两个入口之后
##     该数组已不是当前真值（内容可能过期），要重新取一次；
##   · 允许跨帧持有**同一代**的引用：本类的所有重建路径都"换数组对象"而不是就地改写
##     （见 _rebuild_level），故旧引用内容恒定、读它至少不会撕裂。
##
## 【为什么需要这个入口】视点层一轮可派 200 个粗层任务，每个都 duplicate() 一次整份材质
## 数组只是为了让 worker 读到稳定的值 —— 200 次小数组分配，纯浪费。worker 本来就只读，
## 真正需要的是"这一份在任务在途期间不会被就地改写"这个保证，而该保证由本类的换对象写法
## 提供，不靠拷贝。
func aligned_shared(src: Array, level: int) -> Array:
	return aligned(src, level)


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


## 【必须换数组对象，不能就地 assign】aligned_shared() 把数组对象本身交给了 worker。
## 就地 assign 会在 worker 正在遍历它时改写内容（跨线程读写竞态，且症状随机）。
## 换成"算一份新的再挂回去"，旧引用内容从此恒定，在途任务读到的永远是一个自洽的快照。
func _rebuild_level(src: Array, level: int) -> void:
	_aligned[level] = VoxelMaterial.align_by_id(snapshot(src))
