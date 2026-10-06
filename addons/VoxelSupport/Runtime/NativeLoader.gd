class_name NativeLoader
extends RefCounted

## GDExtension 原生核心桥（VoxelNative）——**硬依赖**。
##
## 插件全部热路径（网格生成 / 崩塌检测 / 批量体素写 / 快照 / CRC）都实现在原生库里，
## 因此不保留任何 GDScript 兜底：库缺失或方法不全时，这里统一报一次错并返回空值。
## 单一实现 = 单一行为，不会出现"有库/无库两条路径表现不一致"。
##
## 【为什么动态绑定】编辑器启动早期（扩展注册完成前）GDScript 静态引用 VoxelNative
## 会直接 SIGKILL；经 ClassDB + Object.call 动态绑定对任何启动时序都安全。

## 必需方法清单（版本不匹配 = 整体不可用，一次性报错）。
const REQUIRED_METHODS: Array[StringName] = [
	&"greedy_merge_dense",
	&"generate_chunk_dense",
	&"generate_lod1_block_dense",
	&"build_halo_from_buffers",
	&"generate_arrays_native",
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
	&"snapshot_chunks_halo",
	&"crc32",
	&"crc32_segments",
	# QVox 块级编解码（原生）：pick+pack 一次完成，替代 GDScript 逐元素扫描
	&"choose_and_pack",
	&"pack_with_codec",
	&"unpack_block",
	&"voxel_value_range",
	# 体素枚举（原生批量）：替代 GDScript 逐体素循环 + 逐体素 Callable / Variant 装箱
	&"collect_all_positions",
	&"collect_all_flat",
	&"collect_bounds",
	&"collect_sphere_positions",
	&"collect_box_positions",
	&"install_flat_voxels",
	&"damage_sphere",
	&"damage_box",
]

static var _inst: Object = null
static var _failed := false


## 取原生实例（懒初始化 + 能力校验）。不可用时返回 null，且只报一次错（不刷屏）。
static func instance() -> Object:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	if _failed:
		return null
	_failed = true
	if not ClassDB.class_exists(&"VoxelNative"):
		push_error("[VoxelSupport] 缺少原生库 VoxelNative（GDExtension 未加载）。"
				+ "请确认 addons/VoxelSupport/Native/ 下有匹配当前平台与 Godot 版本的动态库。")
		return null
	for m in REQUIRED_METHODS:
		if not ClassDB.class_has_method(&"VoxelNative", m, false):
			push_error("[VoxelSupport] 原生库 VoxelNative 缺少方法 '%s'（库与插件版本不匹配）。" % m)
			return null
	_inst = ClassDB.instantiate(&"VoxelNative")
	if _inst == null:
		push_error("[VoxelSupport] VoxelNative 实例化失败，插件不可用。")
	return _inst


## 原生库是否可用（类已注册 + 必需方法齐全）。供 HUD / 演示脚本查询。
static func is_available() -> bool:
	return instance() != null


## 强制重新检测（失败后补装库时调用）。
static func refresh() -> void:
	_failed = false
	_inst = null


# ----------------------------------------------------------------------------
# 桥接方法：一律"取实例 → 为空则返回空值 → 否则动态调用"。
# 返回值形状与原生签名一致（见 voxel_native.h）。
# ----------------------------------------------------------------------------

## 贪婪网格合并（2D 密集网格同材质矩形合并）。grid 会被就地清零已合并格子。
## 返回 {pos, size, val} 三个 PackedInt32Array。
static func merge_dense(grid: PackedInt32Array, width: int, height: int) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"greedy_merge_dense", grid, width, height)


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


## 球体网格（每体素一颗 icosphere，按顶点预算自动降采样）。另含 "step"（实际采样间隔）。
static func generate_spheres_native(voxels: Dictionary, trans_flags: PackedByteArray,
		subdivisions: int, sphere_scale: float, scale: float, vertex_budget: int) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"generate_spheres_native", voxels, trans_flags,
			subdivisions, sphere_scale, scale, vertex_budget)


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


## 列支撑失稳检测：返回 {pos: true}。
## lateral_radius：横向连带塌落的传播半径（体素）；竖向（失去下方支撑）不受限。见原生注释。
static func find_unsupported_around(buffers: Dictionary, removed: Array, lateral_radius: int = 16) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"find_unsupported_around", buffers, removed, lateral_radius)


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


## 批量移除体素（就地改 buffers）。返回 {removed, chunk_removed, buffers, boundary}。
static func remove_voxels_bulk(buffers: Dictionary, positions: Array) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"remove_voxels_bulk", buffers, positions)


## 批量设置同材质体素（就地改 buffers）。返回 {added, chunk_set, buffers, boundary}。
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


## 一段字节的标准 CRC32（含初值 0xFFFFFFFF 与终值异或）。start/length 传 -1 表示"从头/到末尾"。
static func crc32(data: PackedByteArray, start: int = -1, length: int = -1) -> int:
	var inst := instance()
	if inst == null:
		return 0
	return int(inst.call(&"crc32", data, start, length))


## 多段 CRC32：等价于把各段顺序拼接后算一次（免去 GDScript 侧临时拼接）。
static func crc32_segments(data: PackedByteArray, offsets: PackedInt64Array,
		lengths: PackedInt64Array) -> int:
	var inst := instance()
	if inst == null:
		return 0
	return int(inst.call(&"crc32_segments", data, offsets, lengths))


# ----------------------------------------------------------------------------
# QVox 块级编解码（原生）
# ----------------------------------------------------------------------------
# 字节布局权威在 QVoxSpec / docs/QVOX_FORMAT.md；GDScript 侧的 QVoxBlockCodec.unpack 仍是
# 参考实现，编解码往返由 test_qvox_format 做 oracle。

## 为一个块缓冲挑选体积最小的编解码**并直接产出负载**（一次完成，替代 pick+pack 两趟）。
## 返回 {codec:int, payload:PackedByteArray}；EMPTY 时 codec = CODEC_EMPTY 且 payload 为空。
static func choose_and_pack(buf: PackedInt32Array, n: int) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"choose_and_pack", buf, n)


## 按指定 codec 打包块负载（供 codec 已知的路径与测试使用）。EMPTY / 非法 codec 返回空。
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


# ----------------------------------------------------------------------------
# 体素枚举（原生批量）
# ----------------------------------------------------------------------------
# 这四个都只读 buffers（chunk key -> PackedInt32Array(32³)），不修改内容。

## 全部非空体素位置（Array[Vector3i]）。
static func collect_all_positions(buffers: Dictionary) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"collect_all_positions", buffers)


## 全部非空体素的 (x, y, z, mat) 四元组扁平数组。存档载荷用：
## 相比"每个体素一个 4 元素 Array"省掉百万级小对象与约一个数量级内存。
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


## 球内体素位置（判定 dx²+dy²+dz² <= radius²，float 比较）。
static func collect_sphere_positions(buffers: Dictionary, center: Vector3, radius: float) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"collect_sphere_positions", buffers, center, radius)


## 盒内体素位置（闭区间 [min_p, max_p]，体素坐标）。
static func collect_box_positions(buffers: Dictionary, min_p: Vector3i, max_p: Vector3i) -> Array:
	var inst := instance()
	if inst == null:
		return []
	return inst.call(&"collect_box_positions", buffers, min_p, max_p)


## 球内逐体素累伤（一趟完成：框定 chunk → 读材质 → 比硬度 → 累加 / 判移除）。
## 返回 {removed:PackedVector3Array, hardened_pos:PackedVector3Array,
##       hardened_rem:PackedFloat32Array, damage_chunks:{ck: PackedFloat32Array}}。
## **damage_chunks 里是被修改的伤害缓冲，调用方必须写回自己的账本**（同 remove_voxels_bulk 契约）。
static func damage_sphere(buffers: Dictionary, damage_chunks: Dictionary, center: Vector3,
		radius: float, hardness_table: PackedFloat32Array, damage: float,
		use_health: bool) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"damage_sphere", buffers, damage_chunks, center, radius, hardness_table, damage, use_health)


## 盒内逐体素累伤（闭区间 [min_p, max_p]；单个体素 = 退化盒）。契约同 damage_sphere。
static func damage_box(buffers: Dictionary, damage_chunks: Dictionary, min_p: Vector3i,
		max_p: Vector3i, hardness_table: PackedFloat32Array, damage: float,
		use_health: bool) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"damage_box", buffers, damage_chunks, min_p, max_p, hardness_table, damage, use_health)


## 把扁平 (x, y, z, mat) 四元组装回 chunk 缓冲，返回 {chunk_key: PackedInt32Array(32³)}。
static func install_flat_voxels(flat: PackedInt32Array) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"install_flat_voxels", flat)


## 逐体素累加伤害（原生内核），返回 {removed, hardened_pos, hardened_rem, damage_chunks}。
## **damage_chunks 里是被修改的伤害缓冲，调用方必须写回自己的账本**（同 remove_voxels_bulk 契约）。
static func apply_damage(damage_chunks: Dictionary, positions: Array, materials: PackedInt32Array,
		hardness_table: PackedFloat32Array, damage: float, use_health: bool) -> Dictionary:
	var inst := instance()
	if inst == null:
		return {}
	return inst.call(&"apply_damage", damage_chunks, positions, materials, hardness_table, damage, use_health)
