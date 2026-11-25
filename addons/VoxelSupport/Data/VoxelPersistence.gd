@tool
class_name VoxelPersistence
extends RefCounted

## 体素持久化：把"哪些块该落盘 / 怎么编解码"从 QVoxelSource 里收成一处。
##
## 【为什么要独立】改动前同一件事散在 5 个函数里（`_collect_modified_chunk_keys` /
##   `_serialize_voxels_for_storage` / `_serialize_chunks_to_list` / `_serialize_all_voxels` /
##   `_collect_persist_blocks`），而且**两条落盘路径的取舍还不完全一样**：存档接口
##   （save_data / load_data）在无生成器时要连磁盘流一起合并，而资源载荷（.tscn 里的
##   隐藏 storage 属性）在无生成器时只取内存块（磁盘那部分由 stream 自己负责，重复写
##   进资源只会让文件翻倍）。规则散着写时，这种"看起来一样其实差一点"的地方最容易
##   被就地改成一致或一致地改错。
##   现在只有一个决策函数 blocks_to_persist()，差异用一个显式开关表达并写进注释。
##
## 【为什么不持有状态、不认识 QVoxelSource】本类全部 static，上下文用 Dictionary 传
##   （见 ctx()）。反向依赖 QVoxelSource 会形成循环引用，也会把"持久化规则"重新绑死在
##   那个类上；纯函数也才好被测试直接驱动。
##
## 【上下文契约】ctx() 产出的字典，本类只读：
##   "buffers"   Dictionary {Vector3i chunk_key: PackedInt32Array(32³)}   内存块表
##   "dirty"     VoxelDirtyLedger                                       脏账（读 PERSIST）
##   "stream"    VoxelStream | null                                     磁盘流（可为 null）
##   "node"      Node | null                                           生成器（非 null = 程序化源）
##   "grid_size" Vector3i                                              资源载荷里的网格尺寸
##   "materials" Array                                                 仅 save_data 的编排用


## 组装上下文（唯一入口）。
## [param generator] 生成器（QVoxelNode，extends Resource；此处按 Variant 收，
## 免得持久化层反过来依赖那个具体类型 —— 本层只关心"有没有生成器"）。
static func ctx(buffers: Dictionary, dirty: VoxelDirtyLedger, stream: VoxelStream,
		generator: Variant, grid_size_value: Vector3i, mats: Array) -> Dictionary:
	return {
		"buffers": buffers,
		"dirty": dirty,
		"stream": stream,
		"node": generator,
		"grid_size": grid_size_value,
		"materials": mats,
	}


# ── 单一决策：哪些块要落盘 ────────────────────────────────────────────────

## **"哪些块要落盘"的唯一实现**（收敛前散在 5 处）。
##
## 规则：
##   有生成器（node != null）→ 只落盘**用户改过的块**：dirty 账的 PERSIST 标记 ∪ 流中已有的块。
##     未改的块由生成器确定性重算，全量落盘会把 .tscn 撑成上百 MB（曾 734 万体素 → 137MB）。
##   无生成器 → 数据只存在于内存与流里，必须落盘：
##     [param include_stream_only] = true  → 内存全部块 ∪ 流中全部块（save_data 用：
##        存档接口要给出"完整世界"，磁盘上的部分也得合并进来）；
##     [param include_stream_only] = false → 仅内存全部块（资源载荷用：流里那部分由 stream
##        自己负责，重复写进资源只会翻倍文件体积）。
##
## 返回的键序取自字典插入序（与收敛前的行为一致）；调用方不应依赖顺序。
static func blocks_to_persist(c: Dictionary, include_stream_only: bool = true) -> Array:
	var buffers := _buffers_of(c)
	var dirty := _dirty_of(c)
	var stream := _stream_of(c)
	var keys := {}
	if _node_of(c) != null:
		if dirty != null:
			for ck in dirty.keys(0, VoxelDirtyLedger.PERSIST):
				keys[ck] = true
		if stream != null:
			for ck in stream.get_all_chunk_keys(0):
				keys[ck] = true
	else:
		for ck in buffers:
			keys[ck] = true
		if include_stream_only and stream != null:
			for ck in stream.get_all_chunk_keys(0):
				keys[ck] = true
	var out: Array = []
	for ck in keys:
		out.append(ck)
	return out


## "需随资源持久化"的块缓冲 {chunk_key: PackedInt32Array}（资源载荷用；不含纯磁盘块）。
static func collect_persist_blocks(c: Dictionary) -> Dictionary:
	var out := {}
	for ck in blocks_to_persist(c, false):
		var buf := buffer_for(c, ck)
		if not buf.is_empty():
			out[ck] = buf
	return out


## 序列化**需要落盘**的体素为扁平 (x, y, z, mat) 四元组（原生一次收集）。
##
## 只序列化计划内的块：有生成器时未被用户改动的块不写（生成器会重算），
## 故这里不能简单地 `collect_all_flat(全部内存块)`。
static func serialize_flat(c: Dictionary) -> PackedInt32Array:
	var sub := {}
	for ck in blocks_to_persist(c, true):
		var buf := buffer_for(c, ck)
		if not buf.is_empty():
			sub[ck] = buf
	if sub.is_empty():
		return PackedInt32Array()
	return NativeLoader.collect_all_flat(sub)


## 取一块的缓冲（内存优先；未加载则从流读取）。返回空数组 = 两边都没有。
static func buffer_for(c: Dictionary, chunk_key: Vector3i) -> PackedInt32Array:
	var buf: Variant = _buffers_of(c).get(chunk_key)
	if buf != null:
		return buf
	var stream := _stream_of(c)
	if stream != null:
		return stream.load_chunk(chunk_key)
	return PackedInt32Array()


# ── 反序列化（兼容两种历史格式）───────────────────────────────────────────

## 反序列化体素。接受两种载荷：
##   · PackedInt32Array   当前格式（原生整块装回，每块回调一次 on_block）
##   · Array of [x, y, z, mat]   旧格式（逐体素回写，on_voxel）
## 调用方应已清空当前内容，故这里只装不合并。
##
## 【为什么用 Callable 而不是就地改字典】装块要同步维护计数账 / 作废标记（见
## `_install_block_buffer`），逐体素写要维护脏账与伤害账（见 `_write_buffer_impl`）——
## 那些是数据层的不变式，不能由持久化层越权代劳。
static func deserialize(voxel_list: Variant, on_block: Callable, on_voxel: Callable) -> void:
	if voxel_list == null:
		return
	if voxel_list is PackedInt32Array:
		var bufs := NativeLoader.install_flat_voxels(voxel_list)
		for ck in bufs:
			on_block.call(ck, bufs[ck])
		return
	for vox in voxel_list:
		if vox is Array and vox.size() >= 4:
			on_voxel.call(Vector3i(int(vox[0]), int(vox[1]), int(vox[2])), int(vox[3]))


# ── 资源载荷（隐藏 storage 属性）──────────────────────────────────────────

## 编码资源载荷：组装 {v, grid_size, blocks} 后交给 VoxelPayloadCodec 过帧。
## 【为什么是"块表"而非逐体素列表】体素本就按 chunk 对齐存在块表里，直接搬运零转换；
## 逐体素列表要先构造百万级 Array of Arrays 再序列化，峰值内存与耗时都是数倍。
static func encode_payload(c: Dictionary) -> String:
	var gs: Vector3i = c.get("grid_size", Vector3i.ZERO)
	return VoxelPayloadCodec.encode({
		"v": VoxelPayloadCodec.VERSION,
		"grid_size": [gs.x, gs.y, gs.z],
		"blocks": collect_persist_blocks(c),
	})


## 解码资源载荷；返回 null 即载荷无效（调用方按空载荷处理，不猜着读）。
static func decode_payload(value: String) -> Variant:
	return VoxelPayloadCodec.decode(value)


## 载荷里的 grid_size；缺字段 / 形状不对返回 null（调用方保持原尺寸）。
static func payload_grid_size(payload: Dictionary) -> Variant:
	var gs: Variant = payload.get("grid_size")
	if gs is Array and (gs as Array).size() >= 3:
		return Vector3i(int((gs as Array)[0]), int((gs as Array)[1]), int((gs as Array)[2]))
	return null


## 从载荷恢复块缓冲（块表：chunk_key → PackedInt32Array）。缺字段即视为空载荷。
static func apply_payload_blocks(payload: Dictionary, on_block: Callable) -> void:
	var blocks: Variant = payload.get("blocks")
	if not (blocks is Dictionary):
		return
	for key in (blocks as Dictionary):
		on_block.call(key, (blocks as Dictionary)[key])


# ── 上下文读取（缺失字段的兜底，避免调用方传半截字典就崩）────────────────

static func _buffers_of(c: Dictionary) -> Dictionary:
	var b: Variant = c.get("buffers")
	return b if b is Dictionary else {}


static func _dirty_of(c: Dictionary) -> VoxelDirtyLedger:
	var d: Variant = c.get("dirty")
	return d if d is VoxelDirtyLedger else null


static func _stream_of(c: Dictionary) -> VoxelStream:
	var s: Variant = c.get("stream")
	return s if s is VoxelStream else null


## 生成器（QVoxelNode / Resource）或 null。这里不校验具体类型：本层只做 null 判定。
static func _node_of(c: Dictionary) -> Variant:
	return c.get("node")
