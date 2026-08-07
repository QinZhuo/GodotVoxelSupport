class_name NativeLoader
extends RefCounted

## 原生加速加载器（GDExtension 桥接）
##
## 负责检测 VoxelNative (GDExtension C++) 是否可用，并把热路径调用转发给原生实现。
## 设计目标：
##   - 无原生库时静默回退到纯 GDScript 实现（插件仍可全功能运行）
##   - 平台/版本不匹配时（如 Windows 用户没带 dll），不报错、自动回退
##   - 单例懒初始化，避免启动开销
##
## 关键设计：所有原生调用都通过鸭子类型动态调用（ClassDB.instantiate + Object.call），
## 不使用 VoxelNative.xxx() 编译期静态引用。原因：编辑器启动早期（GDExtension
## 加载完成前）GDScript 若静态解析 VoxelNative 的方法会直接崩溃（SIGKILL 无报错），
## 动态调用则完全运行时绑定，任何启动时序都安全。

static var _available: int = -1  # -1=未检测, 0=不可用, 1=可用
static var _inst: Object = null   # VoxelNative 实例缓存（避免重复实例化）
static var _required_methods := [
	&"greedy_merge_dense",
	&"generate_chunk_dense",
	&"find_unsupported_around",
	&"update_support_cache_remove",
]

## 获取原生实例（懒初始化）。返回 null 表示不可用。
static func _get_instance() -> Object:
	if _available == 0:
		return null
	if _inst != null and is_instance_valid(_inst):
		return _inst
	if not ClassDB.class_exists(&"VoxelNative"):
		_available = 0
		return null
	# 校验所有必需方法存在（版本不匹配时整体回退 GDScript）
	for m in _required_methods:
		if not ClassDB.class_has_method(&"VoxelNative", m, false):
			_available = 0
			return null
	_inst = ClassDB.instantiate(&"VoxelNative")
	_available = 1 if _inst != null else 0
	return _inst


## 原生库是否可用（类已注册 + 所有必需方法存在 = 加载成功）
static func is_available() -> bool:
	return _get_instance() != null


## 贪婪网格合并（转发到原生实现，动态调用）
## grid: PackedInt32Array 行优先，0=空；会被就地清零已合并格子
## 返回 {pos, size, val} 三个 PackedInt32Array
static func merge_dense(grid: PackedInt32Array, width: int, height: int) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"greedy_merge_dense", grid, width, height)


## 生成单个 chunk 网格（转发到原生实现，动态调用）
## halo: 18³ 密集光环缓冲；trans_flags: 材质透明标志数组（PackedByteArray，索引=材质ID）
## 返回 {solid_verts, solid_normals, solid_uvs, solid_idxs, trans_verts, ...}
static func generate_chunk_dense(halo: PackedInt32Array, trans_flags: PackedByteArray,
		scale: float, chunk: Vector3i, use_local_space: bool, offset: Vector3) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"generate_chunk_dense", halo, trans_flags, scale, chunk, use_local_space, offset)


## 支撑图失稳检测（转发到原生实现，动态调用）
## buffers: chunk key -> PackedInt32Array(16³) 的密集缓冲快照
## support_cache: pos(Vector3i) -> 下方支撑计数 的快照
## removed: 本次被移除的体素位置数组
## 返回失稳体素集合 Dictionary{pos(Vector3i): true}
static func find_unsupported_around(buffers: Dictionary, support_cache: Dictionary, removed: Array) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"find_unsupported_around", buffers, support_cache, removed)


## 批量移除后计算支撑缓存增量更新（转发到原生实现，动态调用）
## 返回 {removed: Array[Vector3i], updated: {pos: count}} 增量字典，
## 由调用方据此原地修改 _support_cache（避免全量深拷贝 143 万条）
static func update_support_cache_remove(support_cache: Dictionary, buffers: Dictionary, positions: Array) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"update_support_cache_remove", support_cache, buffers, positions)


## 强制重新检测（加载失败后重试时调用）
static func refresh() -> void:
	_available = -1
	_inst = null
