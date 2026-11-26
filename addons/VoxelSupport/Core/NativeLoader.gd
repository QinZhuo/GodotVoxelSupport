class_name NativeLoader
extends RefCounted

## GDExtension 原生核心桥（VoxelSupportNative）——**硬依赖**。

## 原生库的**源码指纹**，必须与 voxel_native.h 里的 VOXEL_NATIVE_API_VERSION 相等。
const EXPECTED_API_VERSION := 2

## 必需方法清单（版本不匹配 = 整体不可用，一次性报错）。
const REQUIRED_METHODS: Array[StringName] = [
	# 版本握手：必须最先存在，否则无法判断库与源码是否同代
	&"api_version",
	&"generate_chunk_dense",
	&"generate_lod1_block_dense",
	&"build_halo_from_buffers",
	&"generate_arrays_native",
	&"generate_arrays_from_chunks_native",
	&"generate_spheres_native",
	&"build_lod_block_halo_from_buffers_native",
	&"patch_lod_block",
	&"patch_lod_block_from_lod",
	&"build_lod_block_halo_from_lod_buffers_native",
	&"find_unsupported_around",
	&"propagate_stress",
	&"collect_materials",
	&"remove_voxels_bulk",
	&"set_voxels_bulk",
	&"collect_chunks",
	&"partition_connected",
	&"find_unsupported_positions",
	&"flood_fill_positions",
	&"snapshot_chunks_halo",
	&"crc32",
	&"crc32_segments",
	# QVX 块级编解码（原生）：pick+pack 一次完成，替代 GDScript 逐元素扫描
	&"choose_and_pack",
	&"pack_with_codec",
	&"unpack_block",
	&"voxel_value_range",
	# 体素枚举（原生批量）：替代 GDScript 逐体素循环 + 逐体素 Callable / Variant 装箱
	&"collect_all_positions",
	&"collect_all_flat",
	&"collect_bounds",
	&"install_flat_voxels",
	# 破坏内核：VoxelDestructible 的硬依赖。
	&"damage_shape",
	# 网格体素化（外部模型导入）
	&"voxelize_mesh",
]

static var _inst: Object = null
static var _failed := false

## 取原生实例（懒初始化 + 能力校验）。
static func instance() -> Object:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	if _failed:
		return null
	if not ClassDB.class_exists(&"VoxelSupportNative"):
		# 不置 _failed、不 push_error：这是启动早期的正常状态，允许惰性重试。
		return null
	for m in REQUIRED_METHODS:
		if not ClassDB.class_has_method(&"VoxelSupportNative", m, false):
			# 类在、方法不在 = 库与源码不同代，重试也不会变好 → 这里才置 _failed 并报错。
			_failed = true
			push_error("[VoxelSupport] 原生库 VoxelSupportNative 缺少方法 '%s'（库与插件版本不匹配）。"
					% m)
			return null
	# 版本握手：方法齐全仍有可能是旧库（旧库也"齐全"，只是行为旧）。
	var inst: Object = ClassDB.instantiate(&"VoxelSupportNative")
	if inst == null:
		_failed = true
		push_error("[VoxelSupport] VoxelSupportNative 实例化失败，插件不可用。")
		return null
	var native_version := int(inst.call(&"api_version"))
	if native_version != EXPECTED_API_VERSION:
		_failed = true
		push_error("[VoxelSupport] 原生库与 GDScript 版本不匹配，请重新构建："
				+ "库 api_version=%d (build %s)，GDScript 期望 %d。"
				% [native_version, str(inst.call(&"build_id")), EXPECTED_API_VERSION]
				+ "改过 addons/VoxelSupport/Native/src/ 下的 C++ 后必须重新构建 GDExtension，"
				+ "否则加载的是旧 dll。")
		return null
	_inst = inst
	return _inst

## 原生库是否可用（类已注册 + 必需方法齐全 + api_version 与源码同代）。
static func is_available() -> bool:
	return instance() != null

## 强制重新检测（失败后补装库时调用）。
static func refresh() -> void:
	_failed = false
	_inst = null

# 桥接方法：一律"取实例 → 为空则返回空值 → 否则动态调用"。

## 单个 chunk 网格（halo: 34³ 密集光环，值 = 材质ID，0 = 空）。
static func generate_chunk_dense(halo: PackedInt32Array, trans_flags: PackedByteArray,
		scale: float, chunk: Vector3i, use_local_space: bool, offset: Vector3) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"generate_chunk_dense", halo, trans_flags, scale, chunk, use_local_space, offset)

## LOD 大块网格（一次性 32³ 大格；halo: 34³ 大格光环）。
static func generate_lod1_block_dense(halo: PackedInt32Array, trans_flags: PackedByteArray,
		scale: float, block_key: Vector3i, offset: Vector3) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"generate_lod1_block_dense", halo, trans_flags, scale, block_key, offset)

## 由 chunk 密集缓冲构建 34³ 光环（中心 32³ + 1 外缘）。
static func build_halo_from_buffers(buffers: Dictionary, chunk: Vector3i) -> PackedInt32Array:
	var inst := instance()
	if inst == null:
		return PackedInt32Array()
	return inst.call(&"build_halo_from_buffers", buffers, chunk)

## 稀疏体素字典 → 网格 arrays（掉落体/大范围破坏：分 chunk + dense + 合并，全在原生）。
static func generate_arrays_native(voxels: Dictionary, trans_flags: PackedByteArray,
		scale: float, offset: Vector3) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"generate_arrays_native", voxels, trans_flags, scale, offset)

## 块缓冲字典 → 网格 arrays（QVX 块级导入：逐 chunk halo + dense 生成 + 合并 + 索引偏移，全在原生）。
static func generate_arrays_from_chunks_native(chunks: Dictionary, trans_flags: PackedByteArray,
		scale: float, offset: Vector3) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"generate_arrays_from_chunks_native", chunks, trans_flags, scale, offset)

## 球体网格（每体素一颗 icosphere，按顶点预算自动降采样）。
static func generate_spheres_native(voxels: Dictionary, trans_flags: PackedByteArray,
		subdivisions: int, sphere_scale: float, scale: float, vertex_budget: int,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"generate_spheres_native", voxels, trans_flags,
			subdivisions, sphere_scale, scale, vertex_budget, offset)

## 由 chunk 缓冲降采样构建 LOD 大块 34³ 大格光环（lod_shift = 每大格 2^shift 体素）。
static func build_lod_block_halo_from_buffers_native(buffers: Dictionary, block_key: Vector3i,
		lod_shift: int) -> PackedInt32Array:
	var inst := instance()
	if inst == null:
		return PackedInt32Array()
	return inst.call(&"build_lod_block_halo_from_buffers_native", buffers, block_key, lod_shift)

## 金字塔增量降采样：只重算 block 内 [rmin,rmax] 脏大格，未脏大格从 coarse 复用。
static func patch_lod_block(buffers: Dictionary, block_key: Vector3i, lod_shift: int,
		coarse: PackedInt32Array, rmin: Vector3i, rmax: Vector3i) -> PackedInt32Array:
	var inst := instance()
	if inst == null:
		return coarse
	return inst.call(&"patch_lod_block", buffers, block_key, lod_shift, coarse, rmin, rmax)

## 逐级上推：当前层（lod>=2）从上一层 coarse 数据降采样。
static func patch_lod_block_from_lod(coarse_buffers: Dictionary, block_key: Vector3i, lod: int,
		coarse: PackedInt32Array, rmin: Vector3i, rmax: Vector3i) -> PackedInt32Array:
	var inst := instance()
	if inst == null:
		return coarse
	return inst.call(&"patch_lod_block_from_lod", coarse_buffers, block_key, lod, coarse, rmin, rmax)

## 由独立 LOD 数据块构建 34³ 大格光环（直接拷大格，无降采样）。
static func build_lod_block_halo_from_lod_buffers_native(buffers: Dictionary,
		block_key: Vector3i) -> PackedInt32Array:
	var inst := instance()
	if inst == null:
		return PackedInt32Array()
	return inst.call(&"build_lod_block_halo_from_lod_buffers_native", buffers, block_key)

## 支撑失稳检测（基线实现）：返回失稳体素集合 {pos: true}。
static func find_unsupported_around(buffers: Dictionary, removed: Array) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"find_unsupported_around", buffers, removed)

## 应力传播（裂纹扩散）：返回断裂体素 Array[Vector3i]。
static func propagate_stress(buffers: Dictionary, removed: Array,
		strength_table: PackedFloat32Array, max_steps: int, force: float, decay: float) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"propagate_stress", buffers, removed, strength_table, max_steps, force, decay)

## 批量收集体素材质 ID：{pos: int}（无体素 → -1）。
static func collect_materials(buffers: Dictionary, positions: Array) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"collect_materials", buffers, positions)

## 批量移除体素（就地改 buffers）。
static func remove_voxels_bulk(buffers: Dictionary, positions: Array) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"remove_voxels_bulk", buffers, positions)

## 批量设置同材质体素（就地改 buffers）。
static func set_voxels_bulk(buffers: Dictionary, positions: Array, material_id: int) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"set_voxels_bulk", buffers, positions, material_id)

## 收集 positions 涉及的 chunk key（去重）。
static func collect_chunks(positions: Array) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"collect_chunks", positions)

## 悬空体素**全量**检测（与地面连通性模型）：输入"全部体素位置"，返回未与 y==0 连通的位置。
static func find_unsupported_positions(positions: Array) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"find_unsupported_positions", positions)

## 集合受限泛洪：在 allowed（Dictionary 作 Set）内，从 seeds（Array[Vector3i]）出发做 6 方向
static func flood_fill_positions(seeds: Array, allowed: Dictionary) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"flood_fill_positions", seeds, allowed)

## 按 6 方向连通性分组：返回 Array[Array[Vector3i]]。
static func partition_connected(positions: Array) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"partition_connected", positions)

## 快照受影响区域的 chunk 缓冲（chunks + 27 邻居，COW 共享）。
static func snapshot_chunks_halo(buffers: Dictionary, chunks: Array) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"snapshot_chunks_halo", buffers, chunks)

## 一段字节的标准 CRC32（含初值 0xFFFFFFFF 与终值异或）。
static func crc32(data: PackedByteArray, start: int = -1, length: int = -1) -> int:
	var inst := instance()
	if inst == null:
		return 0
	return int(inst.call(&"crc32", data, start, length))

## 三角网格 → 调色板索引密集体积（保守表面光栅化 + 内部填充 + 颜色采样 + 量化，全在原生）。
static func voxelize_mesh(verts: PackedVector3Array, indices: PackedInt32Array,
		uvs: PackedVector2Array, colors: PackedColorArray, tri_slots: PackedInt32Array,
		slots: Array, origin: Vector3, cell: float, grid: Vector3i, opts: Dictionary) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"voxelize_mesh", verts, indices, uvs, colors, tri_slots, slots,
			origin, cell, grid, opts)

## 多段 CRC32：等价于把各段顺序拼接后算一次（免去 GDScript 侧临时拼接）。
static func crc32_segments(data: PackedByteArray, offsets: PackedInt64Array,
		lengths: PackedInt64Array) -> int:
	var inst := instance()
	if inst == null:
		return 0
	return int(inst.call(&"crc32_segments", data, offsets, lengths))

# QVX 块级编解码（原生）

## 为一个块缓冲挑选体积最小的编解码**并直接产出负载**（一次完成，替代 pick+pack 两趟）。
static func choose_and_pack(buf: PackedInt32Array, n: int) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"choose_and_pack", buf, n)

## 按指定 codec 打包块负载（供 codec 已知的路径与测试使用）。
static func pack_with_codec(codec: int, buf: PackedInt32Array, n: int) -> PackedByteArray:
	var inst := instance()
	if inst == null:
		return PackedByteArray()
	return inst.call(&"pack_with_codec", codec, buf, n)

## 按 codec 解包块负载，返回长度 n 的缓冲；负载损坏（长度不符 / 游程和 ≠ n / 索引越界）返回空。
static func unpack_block(codec: int, payload: PackedByteArray, n: int) -> PackedInt32Array:
	var inst := instance()
	if inst == null:
		return PackedInt32Array()
	return inst.call(&"unpack_block", codec, payload, n)

## 一块密集缓冲的值域 (min, max)（Vector2i）；空缓冲返回 (0, 0)。
static func voxel_value_range(buf: PackedInt32Array) -> Vector2i:
	var inst := instance()
	if inst == null:
		return Vector2i.ZERO
	return inst.call(&"voxel_value_range", buf)

# 体素枚举（原生批量）

## 全部非空体素位置（Array[Vector3i]）。
static func collect_all_positions(buffers: Dictionary) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"collect_all_positions", buffers)

## 全部非空体素的 (x, y, z, mat) 四元组扁平数组。
static func collect_all_flat(buffers: Dictionary) -> PackedInt32Array:
	var inst := instance()
	if inst == null:
		return PackedInt32Array()
	return inst.call(&"collect_all_flat", buffers)

## 内容包围盒 [min:Vector3i, max:Vector3i]；无体素返回空 Array。
static func collect_bounds(buffers: Dictionary) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"collect_bounds", buffers)

## 统一形状破坏内核（伤害结算下沉原生）：一趟完成"框定 chunk → 读材质 → 比硬度 → 累加 / 判移除"。
static func damage_shape(buffers: Dictionary, damage_chunks: Dictionary, shape: int, center: Vector3,
		radius: float, vmin: Vector3i, vmax: Vector3i, hardness_table: PackedFloat32Array,
		damage: float, use_health: bool, opts: Dictionary = {}) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"damage_shape", buffers, damage_chunks, shape, center, radius, vmin, vmax,
		hardness_table, damage, use_health, opts)

## 把扁平 (x, y, z, mat) 四元组装回 chunk 缓冲，返回 {chunk_key:…
static func install_flat_voxels(flat: PackedInt32Array) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"install_flat_voxels", flat)
