## 材质缓存：把 VoxelRenderer / VoxelDestructible 需要的四份材质派生数据收成一份。
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
func invalidate() -> void:
	_snapshot_dirty = true
	_surfaces = []
	invalidate_aligned()

## 只作废各层对齐数组（block 账本整表清理时用；快照与运行时材质仍然有效）
func invalidate_aligned() -> void:
	for i in _aligned.size():
		_aligned[i] = []

## 权威表的深拷贝（供子线程只读）。
func snapshot(src: Array) -> Array:
	if _snapshot_dirty or _snapshot_src != src:
		_snapshot = src.duplicate(true)
		_snapshot_src = src
		_snapshot_dirty = false
	return _snapshot

## 运行时 Material 对象数组（渲染用）。
func surfaces(src: Array) -> Array:
	if _surfaces.is_empty() or _surfaces[0] == null or _surfaces_src != src:
		_surfaces = VoxelMeshGenerator.generate_textured_materials_runtime(src)
		_surfaces_src = src
	return _surfaces

## 某 LOD 层的对齐数组。
func aligned(src: Array, level: int) -> Array:
	_ensure_level(level)
	if _aligned[level].is_empty():
		_rebuild_level(src, level)
	return _aligned[level]

## 与 aligned() 同值，但语义上**明确"只读共享、不拷贝"**：返回的就是内部缓存那一份数组对象。
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
func _rebuild_level(src: Array, level: int) -> void:
	_aligned[level] = VoxelMaterial.align_by_id(snapshot(src))
