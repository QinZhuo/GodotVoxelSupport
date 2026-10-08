extends TestCase

## 编辑器侧测试：**内核对外契约**（P2-2）。
##
## 【为什么要有这张网】P2-2 的约束是**接口形态**而非行为：
##   "内核公开 API 只有『按 chunk 索引』与『脏区域事件』两种形状"——违反时没有任何运行期症状，
##   只会让无限层慢慢挂不上去（"整块重算"式接口回归、相机 / LOD 概念重新泄漏进内核）。
##   所以只能靠断言把它钉住：
##     ① 公开方法清单 = 契约清单（多一个少一个都失败）；
##     ② 脏区域粒度：单点编辑产生的脏 chunk 数必须是 1（内部点）或 4（chunk 角点），
##        **永不**是"全部 chunk"——这是"按 chunk 索引"的可观测反证。
##
## 【与文档的对应】期望表与 `VoxelRenderer.gd` 顶部"内核对外契约（P2-2）"清单一一对应。
##   增删任何公开方法都必须同时改文档与本表——这正是本测试存在的意义。
##
## 【P2-4 部分】同文件还钉住**编辑内核** `VoxelEditKernel` 的"无节点"性质：
##   它不是 Node、不实现任何帧回调、公开方法清单固定，且**能在完全没有节点的前提下**
##   算完伤害 / 应力 / 失稳——这是"建模画笔 / 服务端不需要挂 VoxelDestructible"的可观测证据。
##
## 【P2-7 部分】以及编辑路径的**增量性**：单点编辑只脏 1 个 chunk、脏账读取即消费、
##   体素计数与全量重数恒等、变空的 chunk 被 O(1) 擦除但留下 mesh 脏标记。
##   这些是"有限内核不会每次落笔全量重算"的可观测证据（256³ 每笔 1670 万格是致命的）。


## 内核公开方法契约（分组与 VoxelRenderer.gd 顶部清单一致）。
const KERNEL_PUBLIC_API: Array[String] = [
	# A. 按 chunk 索引 · 写
	"request_update", "remove_chunk_mesh", "shift_render",
	"mount_lod_mesh", "mark_lod_block_empty", "clear_lod_mesh",
	"set_lod_level_count", "clear_lod_level",
	# B. 按 chunk 索引 · 查
	"has_chunk_mesh", "has_lod_mesh", "lod_mesh", "lod_mesh_keys",
	"is_mesh_build_queued", "lod_materials", "lod_level_count", "surface_materials",
	# C. 只读环境
	"current_camera", "get_data",
	# D. 生命周期覆盖点
	"on_origin_shift",
	# E. 兼容别名 / 插件公开 API（P4 收口）
	"mark_dirty", "force_update", "regenerate_materials",
	"set_voxel", "remove_voxel", "get_voxel",
]


func test_kernel_public_api_matches_contract() -> void:
	var script: Script = load("res://addons/VoxelSupport/Runtime/VoxelRenderer.gd")
	assert_true(script != null, "内核脚本应能加载")
	var actual: Array[String] = []
	for m in script.get_script_method_list():
		var n: String = m["name"]
		# 过滤私有方法（_）与属性访问器伪方法（@data_setter / @data_getter）
		if n.begins_with("_") or n.begins_with("@"):
			continue
		actual.append(n)
	actual.sort()
	var extra: Array[String] = []
	for n in actual:
		if not KERNEL_PUBLIC_API.has(n):
			extra.append(n)
	var missing: Array[String] = []
	for n in KERNEL_PUBLIC_API:
		if not actual.has(n):
			missing.append(n)
	assert_true(extra.is_empty(),
		"内核多出未列入契约的公开方法（视点概念泄漏？）: %s —— 要么改私有，要么补进契约文档与本表" % str(extra))
	assert_true(missing.is_empty(), "契约声明但内核缺失的公开方法: %s" % str(missing))


func test_dirty_regions_are_per_chunk_not_whole_world() -> void:
	# 内部点：恰好脏 1 个 chunk
	var d := _make_data()
	d.set_voxel(Vector3i(10, 10, 10), 1)
	var interior: Array[Vector3i] = d.get_dirty_chunks()
	assert_eq(interior.size(), 1, "内部单点编辑应只脏 1 个 chunk（按 chunk 索引，而非整块重算）")
	assert_eq(interior[0], Vector3i(0, 0, 0), "脏的应是该体素所在的 chunk")
	# 内部点的脏区域**不含**任何邻居 —— 证明不是"整块/整片"重算
	assert_false(interior.has(Vector3i(1, 1, 1)), "内部点编辑不应牵动其他 chunk")

	# chunk 角点：恰好脏 4 个（自身 + 3 个负向邻块）—— 邻块由脏账本按需补齐，永不全量
	var d2 := _make_data()
	d2.set_voxel(Vector3i(32, 32, 32), 1)
	var corner: Array[Vector3i] = d2.get_dirty_chunks()
	assert_eq(corner.size(), 4, "chunk 角点编辑应脏 4 个 chunk（自身 + 3 个负向邻块）")
	for ck: Vector3i in [Vector3i(1, 1, 1), Vector3i(0, 1, 1), Vector3i(1, 0, 1), Vector3i(1, 1, 0)]:
		assert_true(corner.has(ck), "角点编辑应脏相邻 chunk %s" % str(ck))


func test_kernel_chunk_index_queries_are_scoped() -> void:
	var r := VoxelRenderer.new()
	r.voxel_scale = 0.1
	r.data = _make_data()
	r._configure_lod()
	# 按 chunk 查询：未构建的 chunk 一律无网格，且互不影响
	assert_false(r.has_chunk_mesh(Vector3i(0, 0, 0)), "未构建时 chunk (0,0,0) 应无网格")
	assert_false(r.has_chunk_mesh(Vector3i(9, 9, 9)), "未构建时 chunk (9,9,9) 应无网格")
	assert_eq(r.lod_level_count(), 1, "默认应为单层 LOD（分带层数由无限层决定）")
	# 按 chunk 删除幂等，且只作用于目标 chunk
	r.remove_chunk_mesh(Vector3i(0, 0, 0))
	r.remove_chunk_mesh(Vector3i(0, 0, 0))
	assert_false(r.has_chunk_mesh(Vector3i(0, 0, 0)), "按 chunk 删除后该 chunk 应无网格")
	assert_false(r.has_chunk_mesh(Vector3i(9, 9, 9)), "按 chunk 删除不得影响其他 chunk")
	r.free()


# ----------------------------------------------------------------------------
# P2-4：编辑内核 VoxelEditKernel —— 无节点 / 无 _process / 可无头调用
# ----------------------------------------------------------------------------

## 编辑内核公开方法契约（P2-4）。分组与 `VoxelEditKernel.gd` 顶部说明一致。
const EDIT_KERNEL_PUBLIC_API: Array[String] = [
	"apply_damage",      # 伤害结算（范围 → 材质 → 硬度 → 累伤 / 判移除）
	"propagate_stress",  # 应力传播（裂纹扩散）
	"find_unstable",     # 失稳（悬空）检测
	"hardness_table",    # 材质硬度查表（供外部自组调用）
	"strength_table",    # 材质连接强度查表（同上）
]


## 编辑内核的"无节点"性质：不是 Node、不实现任何帧回调、公开面固定。
func test_edit_kernel_is_headless_node_free() -> void:
	var script: Script = load("res://addons/VoxelSupport/Runtime/VoxelEditKernel.gd")
	assert_true(script != null, "编辑内核脚本应能加载")
	var probe = script.new()
	# ① 不是 Node：一旦是 Node 就意味着它能被挂进场景树、被引擎每帧驱动
	assert_false(probe is Node, "编辑内核必须是 RefCounted：挂进场景树就等于承认它需要帧驱动")
	assert_true(probe is RefCounted, "编辑内核应是 RefCounted")
	# ② 不得实现任何帧 / 生命周期回调（分帧调度是节点与表现层的职责）
	var names: Array[String] = []
	for m in script.get_script_method_list():
		names.append(m["name"])
	for forbidden in ["_process", "_physics_process", "_ready", "_enter_tree", "_notification"]:
		assert_false(names.has(forbidden), "编辑内核不得实现 %s（无节点、无帧驱动）" % forbidden)
	# ③ 公开方法清单 = 契约
	var actual: Array[String] = []
	for m in script.get_script_method_list():
		var n: String = m["name"]
		if n.begins_with("_") or n.begins_with("@"):
			continue
		actual.append(n)
	actual.sort()
	var extra: Array[String] = []
	for n in actual:
		if not EDIT_KERNEL_PUBLIC_API.has(n):
			extra.append(n)
	var missing: Array[String] = []
	for n in EDIT_KERNEL_PUBLIC_API:
		if not actual.has(n):
			missing.append(n)
	assert_true(extra.is_empty(), "编辑内核多出未列入契约的公开方法: %s" % str(extra))
	assert_true(missing.is_empty(), "契约声明但编辑内核缺失的公开方法: %s" % str(missing))


## 无头破坏：全程只有 VoxelData + 内核实例，没有任何节点 / 场景树 / 物理 / 粒子。
func test_edit_kernel_resolves_damage_with_no_node() -> void:
	var d := _make_solid(8)
	var k := VoxelEditKernel.new()
	var before := d.get_voxel_count()
	assert_true(before > 0, "测试数据应有体素")
	# 材质硬度 1.0、单发伤害 10 → 命中即摧毁（不必依赖逐体素健康度累加）
	var res := k.apply_damage(d, VoxelEditKernel.SHAPE_SPHERE, Vector3(3.5, 3.5, 3.5), 1.5,
		Vector3i.ZERO, Vector3i.ZERO, 10.0, true)
	var removed: Array = res["removed"]
	assert_true(not removed.is_empty(), "无头调用应能算出被摧毁的体素（不需要任何节点）")
	assert_eq(res["hardened_dirty"], false, "伤害足以摧毁时不应有硬化反馈")
	# 内核只产出"发生了什么"：**不得自行移除体素**（何时落地由调用方决定）
	assert_eq(d.get_voxel_count(), before, "内核不得自行移除体素，只返回待移除位置")
	d.remove_voxels(removed)
	assert_eq(d.get_voxel_count(), before - removed.size(), "调用方移除后体素数应下降")
	k = null


## 无头应力传播 + 失稳检测。
func test_edit_kernel_stress_and_unstable_headless() -> void:
	var d := _make_solid(8)
	var k := VoxelEditKernel.new()
	# connection_strength = 9999 → 应力传播不足以断裂任何东西
	var broken := k.propagate_stress(d, [Vector3i(3, 3, 3)], 3, 15.0, 0.5)
	assert_true(broken is Array, "应力传播应返回体素位置数组")
	assert_eq(broken.size(), 0, "连接强度足够时不应有应力断裂")
	# 接地实心块：无失稳
	assert_eq(k.find_unstable(d, false).size(), 0, "接地实心块不应有失稳体素")
	# 挂一个完全悬空的孤立体素 → 全量检测应检出
	d.set_voxel(Vector3i(100, 100, 100), 1)
	var unstable := k.find_unstable(d, false)
	assert_true(unstable.has(Vector3i(100, 100, 100)), "完全悬空的孤立体素应被检出")
	# 局部检测：只围绕破坏点附近，不碰远处的悬空块
	var local := k.find_unstable(d, true, [Vector3i(3, 3, 3)])
	assert_false(local.has(Vector3i(100, 100, 100)), "局部检测不应扫到远处的悬空块")


## 节点与内核**共用同一份数学**：不存在第二套 GDScript 伤害实现。
func test_destructible_delegates_edit_math_to_kernel() -> void:
	var node := VoxelDestructible.new()
	assert_true(node._edit is VoxelEditKernel, "节点必须持有编辑内核实例（P2-4：数学只有一份）")
	var args := [VoxelEditKernel.SHAPE_SPHERE, Vector3(3.5, 3.5, 3.5), 1.5, Vector3i.ZERO, Vector3i.ZERO]

	var dn := _make_solid(8)
	node.data = dn
	node.damage_per_voxel = 10.0
	node.use_voxel_health = true
	var via_node: Array = node._apply_damage_native(args[0], args[1], args[2], args[3], args[4])
	assert_eq(node.last_damage_count, via_node.size(), "last_damage_count 应与返回的移除数一致")

	var dk := _make_solid(8)
	var via_kernel: Array = VoxelEditKernel.new().apply_damage(
		dk, args[0], args[1], args[2], args[3], args[4], 10.0, true)["removed"]

	var a: Array[String] = []
	for p in via_node:
		a.append(str(p))
	var b: Array[String] = []
	for p in via_kernel:
		b.append(str(p))
	a.sort()
	b.sort()
	assert_true(not a.is_empty(), "节点伤害路径应算出被摧毁体素")
	assert_eq(a, b, "节点与内核直调必须给出同一批被摧毁体素（否则说明数学被复制了一份）")
	node.free()


# ----------------------------------------------------------------------------
# P2-7：编辑路径必须是**脏区域增量**（内核唯一真正的性能风险）
# ----------------------------------------------------------------------------

## 有限内核里"每次落笔全量重算"是致命的（256³ 每笔 1670 万格）。
## 这里把"增量"这件事钉成可观测断言：
##   ① 单点编辑只脏 1 个 chunk（重建粒度 = 脏区域，不是全量）；
##   ② 脏账是"读取即消费"（渲染器每帧 take 一次，不会重复重建）；
##   ③ 体素计数是**增量维护**的，且与全量重数恒等（不存在第二份可漂移的存储）；
##   ④ 归零的 chunk 被 O(1) 擦除，但**必须留下 mesh 脏标记**（否则旧网格不会被清掉）。
func test_edit_path_is_dirty_region_incremental() -> void:
	var d := _make_solid(8)
	var full := d.get_voxel_count()
	assert_eq(full, 512, "8³ 实心块应有 512 体素（全在 chunk (0,0,0)）")
	d.get_dirty_chunks()  # 清掉建场时累积的脏账，从干净状态起测
	assert_true(d.get_dirty_chunks().is_empty(), "清账后应无脏 chunk")

	# ① 单点编辑 → 只脏 1 个 chunk
	d.set_voxel(Vector3i(3, 3, 3), 0)
	var dirty := d.get_dirty_chunks()
	assert_eq(dirty.size(), 1, "单点编辑应只脏 1 个 chunk（增量重建的粒度）")
	assert_eq(dirty[0], Vector3i(0, 0, 0), "脏的应是该体素所在的 chunk")
	# ② 读取即消费：渲染器每帧 take 一次
	assert_true(d.get_dirty_chunks().is_empty(), "脏账应被 take 消费（第二次读取必须为空，否则会重复重建）")

	# ③ 计数增量维护：与全量重数恒等
	assert_eq(d.get_voxel_count(), full - 1, "移除 1 个体素后计数应恰好 -1")
	assert_eq(d.get_voxel_count(), _recount(d), "增量计数必须等于全量重数（否则存在第二份可漂移的存储）")
	assert_eq(d.is_empty(), false, "还有 511 个体素，不该为空")


## ④ 最后一个体素被移除：chunk 被 O(1) 擦除，但 mesh 脏标记必须留下。
func test_empty_chunk_erased_but_mesh_still_marked_dirty() -> void:
	var d := _make_solid(8)
	d.get_dirty_chunks()
	var before := d.get_voxel_count()
	var positions: Array = []
	for x in 8:
		for y in 8:
			for z in 8:
				positions.append(Vector3i(x, y, z))
	d.remove_voxels(positions)
	assert_eq(d.get_voxel_count(), before - positions.size(), "批量移除后计数应归零")
	assert_eq(d.get_voxel_count(), 0, "计数应为 0")
	assert_true(d.is_empty(), "无体素时应为空（O(1) 判空，不变式：计数账只含 > 0 条目）")
	# 关键：chunk 数据已擦除，但渲染器仍须被通知去清掉该 chunk 的旧 mesh
	assert_true(d.get_dirty_chunks().has(Vector3i(0, 0, 0)),
		"变空的 chunk 必须留下 mesh 脏标记，否则渲染器不会重建来清掉旧网格")


# ----------------------------------------------------------------------------
# P4-4：数据层 VoxelData 的 API 稳定等级（公开 / 实验 / 内部）
# ----------------------------------------------------------------------------
#
# 【为什么要有这张网】GDScript 没有访问修饰符，"内部协议"只能靠 `_` 前缀表达。
#   收口前 get_chunk_buffers / accept_chunk_buffer / snapshot_* 等是**不带 `_` 的公开方法**，
#   内核外调用者于是能拿到整张 chunk 缓冲表就地改写、或自行拼 poll+accept 半截协议——
#   这类"绕过封装"没有运行期症状，只会让存储的不变式（体素计数账 / 脏标记 / 快照保护）静默失效。
#   故把它们钉成断言：① 数据层**不带 `_` 的公开方法 = 【公开】∪【实验】**（多一个少一个都失败）；
#   ② 内部协议**只以 `_` 前缀存在**，旧公开名一律不得复活。
#
# 【与文档的对应】两张分级表与 VoxelData.gd 顶部"API 稳定等级（P4-4）"清单一一对应。

## 数据层【公开】稳定 API —— 承诺向后兼容，破坏性改动须走弃用期。
const VOXEL_DATA_PUBLIC_API: Array[String] = [
	# 读写
	"set_voxel", "remove_voxel", "get_voxel", "has_voxel",
	"set_voxels", "remove_voxels", "clear",
	# 区域批量
	"get_voxels_in_sphere", "get_voxels_in_box",
	"remove_voxels_in_sphere", "remove_voxels_in_box",
	"ensure_sphere_loaded", "ensure_box_loaded",
	# 查询统计
	"get_voxel_count", "is_empty", "get_positions", "get_voxels_aabb",
	"get_chunk_voxels", "has_chunk", "get_voxels_dict_snapshot",
	"voxel_bounds", "origin_offset",
	# 材质
	"add_material", "get_material", "get_material_by_id",
	# 脏账事件
	"mark_chunk_dirty", "is_chunk_mesh_dirty", "get_dirty_mesh_chunk_count",
	"get_dirty_chunks", "notify_changed",
	# 存档生命周期
	"save_data", "load_data", "flush", "bake_to", "load_voxels_dict",
	"from_voxel_data", "from_qvox",
	# 连通塌落
	"flood_fill", "find_connected", "connectivity", "neighbors",
	"partition_connected", "find_unsupported", "find_unsupported_around",
	# 数据源
	"set_stream", "is_streaming", "shift_origin",
	# 源失效（源内容变了 → 该块按需重新取数，区别于 unload_chunk 的"卸载"语义）
	"invalidate_chunk_source", "invalidate_chunk_source_range",
]


## 数据层【实验】API —— 可用但形态可能变（收口期仍在动；用前请确认版本）。
const VOXEL_DATA_EXPERIMENTAL_API: Array[String] = [
	# 两级存储查询
	"is_chunk_loaded", "is_stored", "can_supply_chunk", "get_vertical_half_span",
	"get_unloaded_chunk_keys", "get_unloaded_chunk_count", "get_all_chunk_keys",
	"get_loaded_chunk_keys", "preload_chunk", "unload_chunk",
	# 异步取数
	"request_chunk_async", "cancel_chunk_request", "poll_all_ready",
	"apply_ready_results", "is_chunk_pending", "get_unready_chunk_keys",
	# 只读快照
	"begin_readonly_snapshot", "end_readonly_snapshot",
	# 粗层 LOD
	"get_lod_block", "has_lod_block", "set_lod_block", "store_lod_block",
	"erase_lod_block", "get_lod_block_keys", "flush_lod_block",
	"is_lod_block_modified", "patch_lod_block",
	# LOD 脏账
	"invalidate_lod", "invalidate_lod_for_chunk", "mark_lod_modified",
	"mark_lod_modified_for_chunk", "get_lod_dirty_region", "clear_lod_cache",
	"clear_lod_dirty_regions", "get_invalidated_lod", "has_lod_invalidated",
	# 伤害账
	"get_damage", "clear_damage", "clear_damage_bulk", "clear_all_damage",
]


## 数据层【内部】协议（`_` 前缀，内核外不可见）。它们曾是公开 API，内核外调用者
## 能借此绕过封装直改存储 / 拼半截异步协议——P4-4 降为内部，并补了两个封装入口
## （patch_lod_block / apply_ready_results）。
const VOXEL_DATA_INTERNAL_PROTOCOLS: Array[String] = [
	"_chunk_buffers_view", "_lod_buffers_view", "_damage_buffers_view", "_set_damage_buffers",
	"_accept_chunk_buffer", "_chunk_halo", "_snapshot_chunks_halo",
	"_snapshot_lod_block_chunks", "_snapshot_lod_block_chunks_readonly",
	"_snapshot_lod_block_data", "_can_mesh_lod_block_standalone",
]


func test_data_layer_api_tiers_match_contract() -> void:
	var script: Script = load("res://addons/VoxelSupport/Runtime/VoxelData.gd")
	assert_true(script != null, "数据层脚本应能加载")
	var actual: Array[String] = []
	for m in script.get_script_method_list():
		var n: String = m["name"]
		if n.begins_with("_") or n.begins_with("@"):
			continue
		actual.append(n)
	actual.sort()
	var declared: Array[String] = []
	declared.append_array(VOXEL_DATA_PUBLIC_API)
	declared.append_array(VOXEL_DATA_EXPERIMENTAL_API)
	declared.sort()
	var extra: Array[String] = []
	for n in actual:
		if not declared.has(n):
			extra.append(n)
	var missing: Array[String] = []
	for n in declared:
		if not actual.has(n):
			missing.append(n)
	assert_true(extra.is_empty(),
		"数据层多出未分级的公开方法: %s —— 要么标进【公开/实验】表，要么降为 `_` 内部协议" % str(extra))
	assert_true(missing.is_empty(), "契约声明但数据层缺失的公开方法: %s" % str(missing))


func test_data_internal_protocols_are_underscored() -> void:
	var script: Script = load("res://addons/VoxelSupport/Runtime/VoxelData.gd")
	var names: Array[String] = []
	for m in script.get_script_method_list():
		names.append(m["name"])
	# ① 内部协议必须存在，且带 `_` 前缀（内核外不可见）
	for n in VOXEL_DATA_INTERNAL_PROTOCOLS:
		assert_true(names.has(n), "内部协议 %s 应存在" % n)
		assert_true(n.begins_with("_"), "内部协议必须以 `_` 前缀（内核外不可见）: %s" % n)
	# ② 它们绝不能再以"公开"旧名出现（P4-4 前的名字）
	for legacy in ["get_chunk_buffers", "get_lod_buffers", "get_damage_buffers",
			"set_damage_buffers", "accept_chunk_buffer", "snapshot_chunks_halo",
			"snapshot_lod_block_chunks", "snapshot_lod_block_chunks_readonly",
			"snapshot_lod_block_data", "can_mesh_lod_block_standalone", "get_chunk_halo"]:
		assert_false(names.has(legacy),
			"内部协议旧名 %s 不得再作为公开方法存在（应已降为 `_` 前缀）" % legacy)


## 全量重数（独立于增量账本）：用于交叉验证计数账本没有漂移。
func _recount(d: VoxelData) -> int:
	var total := 0
	var buffers := d._chunk_buffers_view()
	for ck in buffers:
		var buf: PackedInt32Array = buffers[ck]
		total += buf.size() - buf.count(0)
	return total


func _make_data() -> VoxelData:
	var d := VoxelData.new()
	var mat := VoxelMaterial.new()
	mat.id = 1
	d.materials = [mat]
	return d


## edge³ 实心块（材质 ID=1，硬度 1.0，连接强度 9999）。索引 0 留空占位以覆盖
## 材质表含 null 的路径（hardness_table / strength_table 必须跳过空条目）。
func _make_solid(edge: int) -> VoxelData:
	var d := VoxelData.new()
	var mats: Array[VoxelMaterial] = []
	mats.resize(2)
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.hardness = 1.0
	mat.connection_strength = 9999.0
	mats[1] = mat
	d.materials = mats
	var positions: Array = []
	for x in edge:
		for y in edge:
			for z in edge:
				positions.append(Vector3i(x, y, z))
	d.set_voxels(positions, 1, false)
	return d
