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
	&"remove_voxels_bulk",
	&"partition_connected",
	&"snapshot_chunks_halo",
	&"generate_arrays_native",
]

## 获取原生实例（懒初始化）。返回 null 表示不可用。
static func _get_instance() -> Object:
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


## LOD1 大块网格（一次性生成 32³ 大格，godot_voxel 风格大 block）。
## halo: 34³ 大格光环（中心 32³ + 1 外缘）；block_key: 大块 key。
static func generate_lod1_block_dense(halo: PackedInt32Array, trans_flags: PackedByteArray,
		scale: float, block_key: Vector3i, offset: Vector3) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"generate_lod1_block_dense", halo, trans_flags, scale, block_key, offset)


## 构建 chunk 的 18³ halo（原生下沉 C++）。无原生/旧库缺方法时返回空数组。
static func build_halo_from_buffers(buffers: Dictionary, chunk: Vector3i) -> PackedInt32Array:
	var inst := _get_instance()
	if inst == null:
		return PackedInt32Array()
	if not ClassDB.class_has_method(&"VoxelNative", &"build_halo_from_buffers", false):
		return PackedInt32Array()
	return inst.call(&"build_halo_from_buffers", buffers, chunk)


## 稀疏体素字典 → 18³ dense halo（掉落体/大破坏 _halo_from_dict 下沉）。无原生时返回空数组。
static func build_halo_from_voxels(voxels: Dictionary, chunk: Vector3i) -> PackedInt32Array:
	var inst := _get_instance()
	if inst == null:
		return PackedInt32Array()
	return inst.call(&"build_halo_from_voxels", voxels, chunk)


## 稀疏体素字典 → 网格 arrays（掉落体大块/大范围破坏核心全 C++：分 chunk + 原生 dense + 合并）。
## 返回与 generate_arrays_runtime 相同的 Dictionary（solid/trans 顶点），无原生时返回空。
static func generate_arrays_native(voxels: Dictionary, trans_flags: PackedByteArray,
		scale: float, offset: Vector3) -> Dictionary:
	var inst := _get_instance()
	if inst == null:
		return {}
	return inst.call(&"generate_arrays_native", voxels, trans_flags, scale, offset)


## 构建 LOD1 大块(32³ 大格)的 34³ halo（原生下沉 C++）。无原生/旧库缺方法时返回空数组。
static func build_lod1_block_halo_from_buffers(buffers: Dictionary, block_key: Vector3i) -> PackedInt32Array:
	var inst := _get_instance()
	if inst == null:
		return PackedInt32Array()
	if not ClassDB.class_has_method(&"VoxelNative", &"build_lod1_block_halo_from_buffers", false):
		return PackedInt32Array()
	return inst.call(&"build_lod1_block_halo_from_buffers", buffers, block_key)


## 构建 LOD 大块的 34³ halo（通用降采样，任意 lod_shift，原生下沉 C++）。
## lod_shift=i → 每大格 2^i 体素。无原生/旧库缺方法时返回空数组。
static func build_lod_block_halo_from_buffers_native(buffers: Dictionary, block_key: Vector3i, lod_shift: int) -> PackedInt32Array:
	var inst := _get_instance()
	if inst == null:
		return PackedInt32Array()
	if not ClassDB.class_has_method(&"VoxelNative", &"build_lod_block_halo_from_buffers_native", false):
		return PackedInt32Array()
	return inst.call(&"build_lod_block_halo_from_buffers_native", buffers, block_key, lod_shift)


## 从独立 LOD 数据块（每 LOD 32³ 大格）构建 34³ halo（直接拷大格，原生下沉 C++）。
## 无原生/旧库缺方法时返回空数组。
static func build_lod_block_halo_from_lod_buffers_native(buffers: Dictionary, block_key: Vector3i) -> PackedInt32Array:
	var inst := _get_instance()
	if inst == null:
		return PackedInt32Array()
	if not ClassDB.class_has_method(&"VoxelNative", &"build_lod_block_halo_from_lod_buffers_native", false):
		return PackedInt32Array()
	return inst.call(&"build_lod_block_halo_from_lod_buffers_native", buffers, block_key)


## 支撑图失稳检测（转发到原生实现，动态调用）
## buffers: chunk key -> PackedInt32Array(16³) 的密集缓冲快照
## removed: 本次被移除的体素位置数组
## 返回失稳体素集合 Dictionary{pos(Vector3i): true}
static func find_unsupported_around(buffers: Dictionary, removed: Array) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"find_unsupported_around", buffers, removed)


## 批量移除体素（转发到原生实现，动态调用）
## buffers: chunk key -> PackedInt32Array(16³)，会被就地修改（值>0 清零）
## positions: 待移除位置数组
## 返回 Dictionary：{removed: int, chunk_removed: {chunk_key: count}}
static func remove_voxels_bulk(buffers: Dictionary, positions: Array) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"remove_voxels_bulk", buffers, positions)


## 批量设置体素为同一材质（转发到原生实现，动态调用）。
## 与原生的 set_voxels_bulk 对称 remove_voxels_bulk；该方法为【可选】能力——
## 旧版原生库无此方法时返回空字典，GDScript 侧回退逐体素循环，不影响其他原生加速。
## 返回 Dictionary：{added, chunk_set, buffers, boundary}
static func set_voxels_bulk(buffers: Dictionary, positions: Array, material_id: int) -> Dictionary:
	var inst := _get_instance()
	if inst == null:
		return {}
	if not ClassDB.class_has_method(&"VoxelNative", &"set_voxels_bulk", false):
		return {}
	return inst.call(&"set_voxels_bulk", buffers, positions, material_id)


## 收集 positions 涉及的 chunk key（去重，转发到原生）。可选能力，无原生时返回空数组。
static func collect_chunks(positions: Array) -> Array:
	var inst := _get_instance()
	if inst == null:
		return []
	if not ClassDB.class_has_method(&"VoxelNative", &"collect_chunks", false):
		return []
	return inst.call(&"collect_chunks", positions)


## 连通分组（转发到原生实现，动态调用）
## positions: Array[Vector3i]，按 6 方向连通分组
## 返回 Array[Array[Vector3i]]
static func partition_connected(positions: Array) -> Array:
	var inst := _get_instance()
	return inst.call(&"partition_connected", positions)


## 快照受影响区域 chunk 缓冲（转发到原生实现，动态调用）
## buffers: chunk key -> PackedInt32Array
## chunks: 需快照的 chunk key 数组（含 27 邻居）
## 返回 Dictionary（COW 共享，省深拷贝）
static func snapshot_chunks_halo(buffers: Dictionary, chunks: Array) -> Dictionary:
	var inst := _get_instance()
	return inst.call(&"snapshot_chunks_halo", buffers, chunks)


## 强制重新检测（加载失败后重试时调用）
static func refresh() -> void:
	_available = -1
	_inst = null
