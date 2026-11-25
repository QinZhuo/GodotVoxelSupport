extends TestCase

## 持久化决策的唯一实现（Data/VoxelPersistence.gd）—— "哪些块该落盘"。
##
## 收敛前这条规则散在 5 个函数里，而且两条落盘路径的取舍**不完全一样**：存档接口
## （save_data / load_data）在无生成器时要连磁盘流一起合并，资源载荷（.tscn 里的隐藏
## storage 属性）在无生成器时只取内存块（磁盘那部分由 stream 自己负责，重复写进资源只会
## 让文件翻倍）。这种"看起来一样其实差一点"的地方，散着写时最容易被就地改成一致或一致
## 地改错 —— 而两种错法都不报错，只会悄悄丢数据或把 .tscn 撑成上百 MB。
##
## 【为什么这个测试不需要场景树/游戏进程】VoxelPersistence 全是 static、上下文用 Dictionary
## 传（不依赖 QVoxelSource），正是为了能被直接驱动。

const AIR := {"rgba": 0, "metal": 0, "rough": 0, "hardness": 0, "mass": 0, "e_r": 0, "e_g": 0, "e_b": 0}


# ── ctx(): 上下文契约 ─────────────────────────────────────────────────────

func test_ctx_exposes_the_six_documented_keys() -> void:
	var stream := VoxelMemoryStream.new()
	var dirty := VoxelDirtyLedger.new()
	var c := VoxelPersistence.ctx({}, dirty, stream, null, Vector3i(1, 2, 3), [])
	for k in ["buffers", "dirty", "stream", "node", "grid_size", "materials"]:
		assert_true(c.has(k), "ctx 必须给出 %s（缺字段会让调用方传半截字典，最终靠兜底静默失效）" % k)
	assert_eq(c["stream"], stream, "stream 原样透传")
	assert_eq(c["grid_size"], Vector3i(1, 2, 3), "grid_size 原样透传")


# ── 有生成器：只落盘用户改过的块 ───────────────────────────────────────────

func test_generator_present_persists_only_dirty_and_streamed_blocks() -> void:
	# 有生成器时，未被用户改动的块由生成器确定性重算。全量落盘曾把 .tscn 撑到 137MB
	# （734 万体素），所以这条"只写改过的"不是优化，是正确性。
	var dirty := VoxelDirtyLedger.new()
	var blocks := {
		Vector3i(0, 0, 0): _only(Vector3i(1, 1, 1), 1),
		Vector3i(1, 0, 0): _only(Vector3i(1, 1, 1), 2),
		Vector3i(2, 0, 0): _only(Vector3i(1, 1, 1), 3),
	}
	dirty.mark(0, Vector3i(1, 0, 0), VoxelDirtyLedger.PERSIST)
	
	var stream := VoxelMemoryStream.new()
	stream.save_chunk(Vector3i(2, 0, 0), blocks[Vector3i(2, 0, 0)])
	
	var c := VoxelPersistence.ctx(blocks, dirty, stream, Resource.new(), Vector3i.ZERO, [])
	var got := VoxelPersistence.blocks_to_persist(c, true)
	assert_eq(got.size(), 2, "只应落盘 dirty(PERSIST) ∪ 流中已有的块")
	assert_true(got.has(Vector3i(1, 0, 0)), "用户改过的块必须落盘")
	assert_true(got.has(Vector3i(2, 0, 0)), "流里已有的块也要落盘（否则磁盘上的会成为孤儿）")
	assert_false(got.has(Vector3i(0, 0, 0)), "没改过、流里也没有的块不该落盘（生成器会重算）")


func test_generator_present_ignores_non_persist_flags() -> void:
	# MESH / LOD_MESH 是渲染账，与"要不要写盘"无关。混进来会让每次重建网格都写一次盘。
	var dirty := VoxelDirtyLedger.new()
	var blocks := {Vector3i.ZERO: _only(Vector3i(0, 0, 0), 1)}
	dirty.mark(0, Vector3i.ZERO, VoxelDirtyLedger.MESH | VoxelDirtyLedger.LOD_MESH)
	var c := VoxelPersistence.ctx(blocks, dirty, null, Resource.new(), Vector3i.ZERO, [])
	assert_eq(VoxelPersistence.blocks_to_persist(c, true).size(), 0,
		"只带 MESH 标记的块不算'需要落盘'")


# ── 无生成器：内存 + 可选流 ───────────────────────────────────────────────

func test_without_generator_include_stream_only_controls_stream_union() -> void:
	# 这正是两条落盘路径唯一分歧的开关，也是本类存在的理由。
	var blocks := {Vector3i.ZERO: _only(Vector3i(0, 0, 0), 1)}
	var stream := VoxelMemoryStream.new()
	stream.save_chunk(Vector3i(5, 0, 0), _only(Vector3i(0, 0, 0), 9))
	var c := VoxelPersistence.ctx(blocks, VoxelDirtyLedger.new(), stream, null, Vector3i.ZERO, [])
	
	var with_stream := VoxelPersistence.blocks_to_persist(c, true)
	assert_eq(with_stream.size(), 2, "include_stream_only=true：存档接口要给出完整世界")
	assert_true(with_stream.has(Vector3i(5, 0, 0)), "流中独有的块也要进存档")
	
	var mem_only := VoxelPersistence.blocks_to_persist(c, false)
	assert_eq(mem_only.size(), 1, "include_stream_only=false：资源载荷只取内存块")
	assert_false(mem_only.has(Vector3i(5, 0, 0)), "流里那部分由 stream 自己负责，重复写进资源只会翻倍体积")


func test_without_generator_and_without_stream_returns_memory_blocks() -> void:
	var blocks := {
		Vector3i(0, 0, 0): _only(Vector3i(0, 0, 0), 1),
		Vector3i(-1, 0, 0): _only(Vector3i(0, 0, 0), 2),
	}
	var c := VoxelPersistence.ctx(blocks, VoxelDirtyLedger.new(), null, null, Vector3i.ZERO, [])
	var got := VoxelPersistence.blocks_to_persist(c, true)
	assert_eq(got.size(), 2, "既无生成器也无流：内存里有什么就落什么")
	assert_eq(VoxelPersistence.blocks_to_persist(c, false).size(), 2, "此时开关无差别（没有流可并）")


func test_missing_context_fields_degrade_to_empty_instead_of_crashing() -> void:
	# 兜底不是"防御式编程"，是让半截上下文变成"什么都没落盘"而不是崩在存档路径上。
	assert_eq(VoxelPersistence.blocks_to_persist({}, true).size(), 0, "空上下文：无块可落")
	assert_eq(VoxelPersistence.collect_persist_blocks({}).size(), 0, "空上下文：空块表")
	assert_eq(VoxelPersistence.serialize_flat({}).size(), 0, "空上下文：空扁平数组")


# ── collect_persist_blocks / serialize_flat ───────────────────────────────

func test_collect_persist_blocks_skips_empty_buffers() -> void:
	# buffer_for 会去流里取；取不到就是空数组 —— 空数组不该作为"一块什么都没有"写进载荷。
	var blocks := {
		Vector3i(0, 0, 0): _only(Vector3i(0, 0, 0), 1),
		Vector3i(1, 0, 0): PackedInt32Array(),
	}
	var c := VoxelPersistence.ctx(blocks, VoxelDirtyLedger.new(), null, null, Vector3i.ZERO, [])
	var out := VoxelPersistence.collect_persist_blocks(c)
	assert_eq(out.size(), 1, "空缓冲不该出现在载荷里")
	assert_true(out.has(Vector3i(0, 0, 0)), "有内容的块必须保留")


func test_serialize_flat_produces_xyz_mat_quadruples() -> void:
	var blocks := {Vector3i(0, 0, 0): _only(Vector3i(2, 3, 4), 7)}
	var c := VoxelPersistence.ctx(blocks, VoxelDirtyLedger.new(), null, null, Vector3i.ZERO, [])
	var flat := VoxelPersistence.serialize_flat(c)
	assert_eq(flat.size(), 4, "一个体素 = 四元组 (x, y, z, mat)")
	assert_eq([flat[0], flat[1], flat[2], flat[3]], [2, 3, 4, 7], "四元组字段顺序为 x,y,z,mat")


# ── buffer_for：内存优先 ──────────────────────────────────────────────────

func test_buffer_for_prefers_memory_over_stream() -> void:
	# 内存里的是"当前编辑结果"，流里的是"上次落盘的样子"。取错的直接后果是
	# 用户刚改的块在存档瞬间回退成旧内容。
	var ck := Vector3i(3, 0, 0)
	var mem := _only(Vector3i(0, 0, 0), 5)
	var stream := VoxelMemoryStream.new()
	stream.save_chunk(ck, _only(Vector3i(0, 0, 0), 6))
	var c := VoxelPersistence.ctx({ck: mem}, VoxelDirtyLedger.new(), stream, null, Vector3i.ZERO, [])
	assert_eq(int(VoxelPersistence.buffer_for(c, ck)[0]), 5, "内存优先，不得被流里的旧值覆盖")
	assert_eq(int(VoxelPersistence.buffer_for(c, Vector3i(9, 0, 0)).size()), 0,
		"两边都没有时返回空数组（而不是 null 或崩溃）")


# ── 反序列化：两种历史格式 ────────────────────────────────────────────────

func test_deserialize_flat_payload_calls_on_block_once_per_chunk() -> void:
	var blocks := {
		Vector3i(0, 0, 0): _only(Vector3i(1, 1, 1), 1),
		Vector3i(-1, 0, 0): _only(Vector3i(2, 2, 2), 2),
	}
	var c := VoxelPersistence.ctx(blocks, VoxelDirtyLedger.new(), null, null, Vector3i.ZERO, [])
	var flat := VoxelPersistence.serialize_flat(c)
	
	var got: Dictionary = {}
	var per_voxel := 0
	VoxelPersistence.deserialize(flat,
		func(ck: Vector3i, buf: PackedInt32Array) -> void: got[ck] = buf,
		func(_p: Vector3i, _m: int) -> void: per_voxel += 1)
	assert_eq(got.size(), blocks.size(), "整块装回：每块回调一次")
	assert_eq(per_voxel, 0, "扁平格式不该走逐体素回调")
	assert_eq(int(got[Vector3i(0, 0, 0)][VoxelChunk.buf_index(1, 1, 1)]), 1, "块内位置与材质应还原")


func test_deserialize_legacy_array_calls_on_voxel() -> void:
	# 旧存档是 Array of [x, y, z, mat]。兼容分支不能删：用户的旧稿还在。
	var picks: Array = []
	var blocks := 0
	VoxelPersistence.deserialize([[1, 2, 3, 4], [5, 6, 7, 8]],
		func(_ck: Vector3i, _buf: PackedInt32Array) -> void: blocks += 1,
		func(pos: Vector3i, mat: int) -> void: picks.append([pos, mat]))
	assert_eq(blocks, 0, "旧格式不该走整块回调")
	assert_eq(picks.size(), 2, "逐体素回调两次")
	assert_eq(picks[0][0], Vector3i(1, 2, 3), "坐标还原")
	assert_eq(picks[0][1], 4, "材质还原")


func test_deserialize_null_is_a_noop() -> void:
	var calls := 0
	VoxelPersistence.deserialize(null,
		func(_ck: Vector3i, _buf: PackedInt32Array) -> void: calls += 1,
		func(_p: Vector3i, _m: int) -> void: calls += 1)
	assert_eq(calls, 0, "null 载荷是合法的（空存档），不该回调也不该崩")


# ── 资源载荷编解码 ────────────────────────────────────────────────────────

func test_payload_roundtrip_keeps_grid_size_and_blocks() -> void:
	var blocks := {Vector3i(0, 0, 0): _only(Vector3i(1, 1, 1), 3)}
	var c := VoxelPersistence.ctx(blocks, VoxelDirtyLedger.new(), null, null, Vector3i(16, 32, 8), [])
	var text := VoxelPersistence.encode_payload(c)
	assert_true(text.length() > 0, "载荷应是 base64 文本（不是空串）")
	
	var payload: Variant = VoxelPersistence.decode_payload(text)
	assert_true(payload is Dictionary, "解码应得到 Dictionary")
	assert_eq(VoxelPersistence.payload_grid_size(payload), Vector3i(16, 32, 8), "grid_size 往返一致")
	
	var back: Dictionary = {}
	VoxelPersistence.apply_payload_blocks(payload,
		func(ck: Vector3i, buf: PackedInt32Array) -> void: back[ck] = buf)
	assert_eq(back.size(), 1, "块表应还原")
	assert_eq(int(back[Vector3i(0, 0, 0)][VoxelChunk.buf_index(1, 1, 1)]), 3, "块内容应还原")


func test_payload_is_gzip_compressed_not_raw_bytes() -> void:
	# 载荷进了 .tscn，未压缩时百万体素会让场景文件变成上百 MB。
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	buf.fill(0)
	var blocks := {Vector3i.ZERO: buf}
	var c := VoxelPersistence.ctx(blocks, VoxelDirtyLedger.new(), null, null, Vector3i.ZERO, [])
	var flat := VoxelPersistence.serialize_flat(c)
	assert_eq(flat.size(), 0, "全零块本就是空块，不该进扁平数组（此处仅确认前提）")
	# 用真实内容比对长度：压缩后应显著短于原始 4·N 字节。
	var real := {Vector3i.ZERO: _only(Vector3i(1, 1, 1), 1)}
	var c2 := VoxelPersistence.ctx(real, VoxelDirtyLedger.new(), null, null, Vector3i.ZERO, [])
	var text := VoxelPersistence.encode_payload(c2)
	assert_true(text.length() < VoxelChunk.CHUNK_VOLUME * 2,
		"压缩后的载荷应远小于一整块体素（实际 %d 字符 vs %d 体素）" % [text.length(), VoxelChunk.CHUNK_VOLUME])


# 【这里刻意不测"垃圾串被拒绝"】decode_payload 对不可信输入的正确行为就是 push_error 后
# 返回 null，而本 runner 会把用例里发生的 push_error 记成失败（全仓 11 条既有失败正是这个
# 成因）。钉这个行为只能用"预期报错"的写法，而那会让每次全量回归多出两条噪音失败。
# 拒绝逻辑本身在 VoxelPayloadCodec.decode 里是单点实现（魔数 / 解压 / 版本三道），
# 由格式层的 test_qvoxel_project / test_voxel_fix_regressions 覆盖。


func test_payload_grid_size_returns_null_on_bad_shape() -> void:
	assert_eq(VoxelPersistence.payload_grid_size({}), null, "缺字段 → null（调用方保持原尺寸）")
	assert_eq(VoxelPersistence.payload_grid_size({"grid_size": [1, 2]}), null, "不足 3 元 → null")
	assert_eq(VoxelPersistence.payload_grid_size({"grid_size": "abc"}), null, "非数组 → null")
	assert_eq(VoxelPersistence.payload_grid_size({"grid_size": [1, 2, 3]}), Vector3i(1, 2, 3), "正常形状 → 向量")


# ── helpers ───────────────────────────────────────────────────────────────

## 一个只在 pos 处有材质 mat 的 32³ 块。
func _only(pos: Vector3i, mat: int) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	buf[VoxelChunk.buf_index(pos.x, pos.y, pos.z)] = mat
	return buf
