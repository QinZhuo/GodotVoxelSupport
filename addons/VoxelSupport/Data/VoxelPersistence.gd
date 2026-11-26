@tool
class_name VoxelPersistence
extends RefCounted

## 体素持久化：把"哪些块该落盘 / 怎么编解码"从 QVoxelSource 里收成一处。

## 组装上下文（唯一入口）。
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
static func serialize_flat(c: Dictionary) -> PackedInt32Array:
	var sub := {}
	for ck in blocks_to_persist(c, true):
		var buf := buffer_for(c, ck)
		if not buf.is_empty():
			sub[ck] = buf
	if sub.is_empty():
		return PackedInt32Array()
	return NativeLoader.collect_all_flat(sub)

## 取一块的缓冲（内存优先；未加载则从流读取）。
static func buffer_for(c: Dictionary, chunk_key: Vector3i) -> PackedInt32Array:
	var buf: Variant = _buffers_of(c).get(chunk_key)
	if buf != null:
		return buf
	var stream := _stream_of(c)
	if stream != null:
		return stream.load_chunk(chunk_key)
	return PackedInt32Array()

# ── 反序列化（兼容两种历史格式）───────────────────────────────────────────

## 反序列化体素。
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

## 从载荷恢复块缓冲（块表：chunk_key → PackedInt32Array）。
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

## 生成器（QVoxelNode / Resource）或 null。
static func _node_of(c: Dictionary) -> Variant:
	return c.get("node")
