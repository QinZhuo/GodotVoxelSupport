extends TestCase

## QVX 块流布局（Format/QVoxelBlockStream.gd）的字节级契约。
##
## 这个类存在的唯一理由是"布局只有一处实现"：此前 17 字节子块头、12 字节顶层块头、
## MATE/VXEL/ANIM/CACH/JSON 五种负载散在 QVoxelFile 的 1700 行里各写一遍，偏移量
## （+4 / +8 / +12 / +13）全是手抄的魔法数。下面的用例不复述 QVoxelFile 的读写策略，
## 只钉"写出来的字节是什么样、读回来的东西是否等价"。

const BLOCK_SIZE := VoxelChunk.CHUNK_SIZE
const BLOCK_VOLUME := VoxelChunk.CHUNK_VOLUME


# ── 顶层块 framing ────────────────────────────────────────────────────────

func test_write_block_framing_is_length_type_crc_payload_padding() -> void:
	var out := PackedByteArray()
	var payload := "hello".to_ascii_buffer()
	QVoxelBlockStream.write_block(out, QVoxelSpec.BLOCK_HEAD, payload, true)
	
	var padded := QVoxelSpec.padded_length(payload.size())
	assert_eq(out.size(), QVoxelSpec.BLOCK_HEADER_SIZE + padded, "整块 = 12 字节头 + 对齐后的负载")
	assert_eq(out.decode_u32(0), padded, "length 字段含填充（读取端靠 seek(length) 落到下一块头）")
	assert_eq(padded % QVoxelSpec.BLOCK_ALIGN, 0, "length 必须是 4 的倍数")
	assert_eq(QVoxelBlockStream.read_type(out, 4), QVoxelSpec.BLOCK_HEAD, "type 在 +4，4 个 ASCII 字符")
	assert_eq(out.decode_u32(8), QVoxelBlockStream.block_crc(out, 0, padded), "crc 在 +8，覆盖 length‖type‖负载")
	for i in payload.size():
		assert_eq(out[QVoxelSpec.BLOCK_HEADER_SIZE + i], payload[i], "负载从 +12 起逐字节一致")
	for i in range(payload.size(), padded):
		assert_eq(out[QVoxelSpec.BLOCK_HEADER_SIZE + i], 0, "尾部填充为 0")


func test_write_block_without_crc_stores_zero_not_a_valid_crc() -> void:
	# 格式约定 "0 = 无校验值"，不是"校验通过"。否则不写 CRC 的文件会被误判成损坏。
	var out := PackedByteArray()
	QVoxelBlockStream.write_block(out, QVoxelSpec.BLOCK_NODE, "{}".to_utf8_buffer(), false)
	assert_eq(out.decode_u32(8), 0, "include_crc=false 时 crc 字段写 0")
	assert_ne(QVoxelBlockStream.block_crc(out, 0, out.decode_u32(0)), 0, "而真实的 crc 通常不是 0")


func test_block_crc_covers_padding_bytes() -> void:
	# 若 crc 只覆盖负载正文，则"同一份内容、不同填充字节"的两个文件校验值相同，
	# 而 A 会认为 B 是自己 —— 增量写盘靠 crc 判断"这个块是不是原来的那个"。
	var a := PackedByteArray()
	QVoxelBlockStream.write_block(a, QVoxelSpec.BLOCK_NODE, "{}".to_utf8_buffer(), true)
	var b := a.duplicate()
	b[b.size() - 1] = 1   # 只改填充字节
	assert_ne(a.decode_u32(8), QVoxelBlockStream.block_crc(b, 0, b.decode_u32(0)),
		"填充字节参与 crc：改一个填充位就该算出不同的校验值")


func test_multiple_blocks_are_independently_addressable() -> void:
	var out := PackedByteArray()
	QVoxelBlockStream.write_block(out, QVoxelSpec.BLOCK_HEAD, "qvx".to_utf8_buffer(), true)
	QVoxelBlockStream.write_block(out, QVoxelSpec.BLOCK_MATE, PackedByteArray([0, 0]), true)
	var pos := 0
	var types: Array = []
	while pos + QVoxelSpec.BLOCK_HEADER_SIZE <= out.size():
		var length := out.decode_u32(pos)
		types.append(QVoxelBlockStream.read_type(out, pos + 4))
		pos += QVoxelSpec.BLOCK_HEADER_SIZE + length
	assert_eq(types, [QVoxelSpec.BLOCK_HEAD, QVoxelSpec.BLOCK_MATE], "块按写入顺序串联")
	assert_eq(pos, out.size(), "按 length 前进应当恰好走完全部字节")


func test_slice_crc_matches_native_crc32() -> void:
	var data := PackedByteArray()
	data.resize(64)
	for i in 64:
		data[i] = (i * 37) & 0xFF
	assert_eq(QVoxelBlockStream.slice_crc(data, 0, data.size()),
		NativeLoader.crc32(data, 0, data.size()), "slice_crc 就是原生 crc32 的转发（不另写实现）")
	assert_eq(QVoxelBlockStream.slice_crc(data, 8, 16),
		NativeLoader.crc32(data, 8, 16), "带偏移的切片也一致")


# ── VXEL / ANIM 内层子块（17 字节头）────────────────────────────────────

func test_sub_block_roundtrip_keeps_signed_keys_and_codec() -> void:
	var out := PackedByteArray()
	var keys := [Vector3i.ZERO, Vector3i(-1, 2, -3), Vector3i(1000, -1000, 7)]
	for i in keys.size():
		QVoxelBlockStream.write_sub_block(out, keys[i], QVoxelSpec.CODEC_SOLID,
			PackedByteArray([i, i + 1, i + 2]))
	var at := 0
	for i in keys.size():
		var sub := QVoxelBlockStream.read_sub_block(out, at, out.size())
		assert_eq(sub.get("key"), keys[i], "块坐标往返一致（负数必须靠 to_u32/from_u32 保真）")
		assert_eq(int(sub.get("codec")), QVoxelSpec.CODEC_SOLID, "codec 在 +12")
		assert_eq(int(sub.get("payload_len")), 3, "payload_length 在 +13")
		assert_eq(sub.get("total"), QVoxelSpec.VOX_BLOCK_HEADER_SIZE + 3, "total 用于前进到下一子块")
		assert_eq(out[int(sub.get("payload_off"))], i, "负载起点 = 头之后")
		at += int(sub.get("total"))
	assert_eq(at, out.size(), "子块串联应恰好走完")


func test_sub_block_returns_empty_on_truncation() -> void:
	# 截断的文件必须被识别成"该模型损坏 DROP_MODEL"，而不是读越界内存后崩。
	var out := PackedByteArray()
	QVoxelBlockStream.write_sub_block(out, Vector3i(1, 1, 1), QVoxelSpec.CODEC_DENSE,
		PackedByteArray([1, 2, 3, 4]))
	assert_eq(QVoxelBlockStream.read_sub_block(out, 0, out.size() - 1).size(), 0,
		"负载越过 limit 应返回空字典")
	assert_eq(QVoxelBlockStream.read_sub_block(out, out.size(), out.size()).size(), 0,
		"头都不完整应返回空字典")
	assert_false(QVoxelBlockStream.read_sub_block(out, 0, out.size()).is_empty(),
		"完整时应当读得出来（否则上两条会假通过）")


# ── JSON 块 ───────────────────────────────────────────────────────────────

func test_json_block_strips_trailing_zero_padding() -> void:
	var out := PackedByteArray()
	QVoxelBlockStream.write_block(out, QVoxelSpec.BLOCK_NODE, QVoxelBlockStream.encode_json({"nodes": []}), true)
	var length := out.decode_u32(0)
	var payload := out.slice(QVoxelSpec.BLOCK_HEADER_SIZE, QVoxelSpec.BLOCK_HEADER_SIZE + length)
	assert_eq(QVoxelBlockStream.decode_json(payload).get("nodes"), [], "尾部零填充应被剥掉再解析")
	assert_eq(QVoxelBlockStream.decode_json(PackedByteArray()).size(), 0, "空负载解析为空字典")
	assert_eq(QVoxelBlockStream.decode_json(PackedByteArray([0, 0, 0])).size(), 0, "全零负载解析为空字典")


func test_encode_json_keeps_insertion_order() -> void:
	# JSON.stringify 默认按**键名字典序**重排，会把 "qvox" 挤到后面。qvx 规范要求它是第一键。
	var d := {"zzz": 1, "qvox": 4, "aaa": 2}
	var text := QVoxelBlockStream.encode_json(d).get_string_from_utf8()
	assert_true(text.begins_with("{\"zzz\""), "sort_keys=false：保持插入顺序（实际输出 %s）" % text)


func test_encode_head_puts_qvox_first_even_when_inserted_last() -> void:
	var head := {
		QVoxelSpec.HEAD_CHANNEL_KEY: QVoxelSpec.DOMINANT_CHANNEL,
		QVoxelSpec.HEAD_BPP_KEY: QVoxelSpec.CHANNEL_BPP,
		"qvox": QVoxelSpec.VERSION,
	}
	var text := QVoxelBlockStream.encode_head(head).get_string_from_utf8()
	assert_true(text.begins_with("{\"qvox\""), "编码器自己重排，不靠调用方塞键顺序（实际 %s）" % text)
	assert_eq(QVoxelBlockStream.head_with_qvox_first({}), {}, "无 qvox 时原样返回空字典")


# ── VXEL ─────────────────────────────────────────────────────────────────

func test_encode_vxel_header_and_empty_block_skipping() -> void:
	var blocks := {
		Vector3i(0, 0, 0): _solid_block(1),
		Vector3i(1, 0, 0): PackedInt32Array(),      # 全零块 = 坐标缺失，不该出现在字节里
	}
	var payload := QVoxelBlockStream.encode_vxel(7, blocks, BLOCK_SIZE)
	assert_eq(payload.decode_u16(0), 7, "model_id 在 +0（uint16）")
	assert_eq(payload.decode_u32(2), 1, "块数在 +2，空块不计入")
	assert_eq(payload.decode_u32(6) + QVoxelSpec.VXEL_MODEL_HEADER_SIZE, payload.size(),
		"payload_length 精确界定 block[] 的字节数")
	var sub := QVoxelBlockStream.read_sub_block(payload, QVoxelSpec.VXEL_MODEL_HEADER_SIZE, payload.size())
	assert_eq(sub.get("key"), Vector3i.ZERO, "唯一的子块就是非空那个")


func test_encode_vxel_is_byte_deterministic_regardless_of_insertion_order() -> void:
	# 落盘字节的确定性、增量写的块搬运、回归测试的逐字节哈希都押在这一点上。
	var a := {Vector3i(1, 0, 0): _solid_block(2), Vector3i(0, 0, 0): _solid_block(1)}
	var b := {Vector3i(0, 0, 0): _solid_block(1), Vector3i(1, 0, 0): _solid_block(2)}
	assert_eq(QVoxelBlockStream.encode_vxel(0, a, BLOCK_SIZE),
		QVoxelBlockStream.encode_vxel(0, b, BLOCK_SIZE), "字典插入序不同也必须写出同一串字节")


func test_encode_vxel_skips_forged_empty_arrays() -> void:
	var blocks := {Vector3i.ZERO: PackedInt32Array()}
	var payload := QVoxelBlockStream.encode_vxel(0, blocks, BLOCK_SIZE)
	assert_eq(payload.decode_u32(2), 0, "全空块表写出的块数为 0")
	assert_eq(payload.size(), QVoxelSpec.VXEL_MODEL_HEADER_SIZE, "没有任何子块负载")


# ── ANIM：块级增量 ────────────────────────────────────────────────────────

func test_encode_anim_first_frame_is_full_then_only_deltas() -> void:
	var f0 := {"duration_ms": 100, "blocks": {
		Vector3i(0, 0, 0): _solid_block(1),
		Vector3i(1, 0, 0): _solid_block(1)}}
	var f1 := {"duration_ms": 100, "blocks": {
		Vector3i(0, 0, 0): _solid_block(1),      # 与上一帧相同 → 不写
		Vector3i(1, 0, 0): _solid_block(2),      # 变了 → 写
		Vector3i(2, 0, 0): _solid_block(3)}}     # 新增 → 写
	var payload := QVoxelBlockStream.encode_anim(0, [f0, f1], {}, BLOCK_SIZE)
	assert_eq(payload.decode_u16(0), 0, "model_id 在 +0（uint16）")
	assert_eq(payload.decode_u16(2), 2, "帧数在 +2（uint16）")
	assert_eq(payload.decode_u32(4) + QVoxelSpec.ANIM_MODEL_HEADER_SIZE, payload.size(),
		"payload_length 精确界定 帧数组 的字节数")
	
	var at := QVoxelSpec.ANIM_MODEL_HEADER_SIZE
	var meta_len := payload.decode_u32(at)
	assert_eq(meta_len, 0, "缺省 meta 不写（meta_len=0）")
	at += 4 + meta_len
	
	var d0 := payload.decode_u32(at + 2)
	at += QVoxelSpec.ANIM_FRAME_HEADER_SIZE
	assert_eq(_count_sub_blocks(payload, at, d0), 2, "帧 0 相对空基线写全量")
	at += d0
	
	var d1 := payload.decode_u32(at + 2)
	at += QVoxelSpec.ANIM_FRAME_HEADER_SIZE
	assert_eq(_count_sub_blocks(payload, at, d1), 2, "帧 1 只写 2 个变化的块（相同块不写）")
	at += d1
	assert_eq(at, payload.size(), "帧数组应恰好走完")


func test_encode_anim_writes_clears_as_empty_codec() -> void:
	var f0 := {"duration_ms": 1, "blocks": {Vector3i(0, 0, 0): _solid_block(1)}}
	var f1 := {"duration_ms": 1, "blocks": {}}
	var payload := QVoxelBlockStream.encode_anim(0, [f0, f1], {}, BLOCK_SIZE)
	var at := QVoxelSpec.ANIM_MODEL_HEADER_SIZE + 4
	var d0 := payload.decode_u32(at + 2)
	at += QVoxelSpec.ANIM_FRAME_HEADER_SIZE + d0
	var d1 := payload.decode_u32(at + 2)
	at += QVoxelSpec.ANIM_FRAME_HEADER_SIZE
	var sub := QVoxelBlockStream.read_sub_block(payload, at, at + d1)
	assert_eq(int(sub.get("codec")), QVoxelSpec.CODEC_EMPTY,
		"消失的块必须显式写 codec=0（这是 ANIM 专有语义：'清空'不能靠'缺失'表达）")


func test_anim_meta_omits_defaults_and_roundtrips() -> void:
	assert_eq(QVoxelBlockStream.anim_meta_json({}), {}, "空 meta 全缺省")
	assert_eq(QVoxelBlockStream.anim_meta_json(
		{"fps": QVoxelSpec.ANIM_FPS_DEFAULT, "loop": QVoxelSpec.ANIM_LOOP_DEFAULT}), {},
		"等于缺省值的字段不写（省字节且让'未设置'与'设成默认'字节相同）")
	var d := QVoxelBlockStream.anim_meta_json({"fps": 24, "loop": false, "tags": ["a"]})
	assert_eq(int(d.get("fps")), 24, "非缺省 fps 写入")
	assert_eq(bool(d.get("loop")), false, "非缺省 loop 写入")
	assert_eq(QVoxelBlockStream.anim_meta_from_json(d),
		{"fps": 24, "loop": false, "tags": ["a"]}, "归一化后应还原成同一份")
	assert_eq(QVoxelBlockStream.anim_meta_from_json({}).get("fps"),
		QVoxelSpec.ANIM_FPS_DEFAULT, "缺字段补缺省 fps（真值在 QVoxelSpec.ANIM_FPS_DEFAULT）")
	assert_eq(QVoxelBlockStream.anim_meta_from_json({}).get("loop"),
		QVoxelSpec.ANIM_LOOP_DEFAULT, "缺字段补缺省 loop")


# ── CACH ─────────────────────────────────────────────────────────────────

func test_cach_roundtrip_keeps_kind_version_and_source_crcs() -> void:
	var entry := {
		"kind": "LODS",
		"algo_version": 3,
		"source_crc": [0x01020304, 0xAABBCCDD],
		"payload": "body".to_utf8_buffer(),
	}
	var payload := QVoxelBlockStream.encode_cach(entry)
	assert_eq(payload.size(),
		QVoxelSpec.CACH_PREFIX_SIZE + 2 * 4 + 4, "8 字节前置 + 2 个 uint32 + 内容")
	var parsed: Variant = QVoxelBlockStream.parse_cach(payload)
	assert_true(parsed is Dictionary, "结构合法应解析成功")
	assert_eq((parsed as Dictionary).get("kind"), "LODS", "kind 是 4 个 ASCII 字符")
	assert_eq(int((parsed as Dictionary).get("algo_version")), 3, "algo_version 在 +4（uint16）")
	assert_eq((parsed as Dictionary).get("source_crc"), [0x01020304, 0xAABBCCDD],
		"来源 crc 列表在 +8 起")
	assert_eq(((parsed as Dictionary).get("payload") as PackedByteArray).get_string_from_utf8(),
		"body", "内容起点由 content_off 界定")


func test_cach_header_reports_content_offset_without_copying_payload() -> void:
	# QVoxelStream 的 CACH 索引只为"建索引"解析头部，不为每个缓存条目复制一份负载。
	var entry := {"kind": "MESH", "algo_version": 1, "source_crc": [7], "payload": PackedByteArray([1, 2, 3])}
	var payload := QVoxelBlockStream.encode_cach(entry)
	var hdr := QVoxelBlockStream.parse_cach_header(payload)
	assert_eq(int(hdr.get("content_off")), QVoxelSpec.CACH_PREFIX_SIZE + 4, "content_off = 前置 + 来源表")
	assert_false(hdr.has("payload"), "头部解析不该切出内容字节（否则每次索引都多一次复制）")


func test_cach_parse_rejects_short_payload() -> void:
	# parse_cach 的契约是"结构非法返回 null"（而不是空字典）：它把 payload 装进返回值里，
	# 空字典会被调用方当成"有头部但没内容"。故这里断言 null，别用 .size()。
	assert_eq(QVoxelBlockStream.parse_cach(PackedByteArray()), null, "空负载无头部，应返回 null")
	assert_eq(QVoxelBlockStream.parse_cach_header(PackedByteArray([1, 2])).size(), 0, "不足 8 字节无头部")
	var lying := PackedByteArray()
	lying.resize(QVoxelSpec.CACH_PREFIX_SIZE)
	lying.encode_u16(6, 3)   # 声称 3 个来源 crc，实际一个字节都没有
	assert_eq(QVoxelBlockStream.parse_cach_header(lying).size(), 0, "越界应判非法")


func test_append_cach_blocks_frames_a_real_top_level_block() -> void:
	var out := PackedByteArray()
	QVoxelBlockStream.append_cach_blocks(out, [{"kind": "LODS", "algo_version": 1}], true)
	assert_eq(QVoxelBlockStream.read_type(out, 4), QVoxelSpec.BLOCK_CACH, "CACH 是一等顶层块")
	var length := out.decode_u32(0)
	assert_eq(out.size(), QVoxelSpec.BLOCK_HEADER_SIZE + length, "按顶层块 framing 写出")
	assert_ne(out.decode_u32(8), 0, "默认带 crc")


# ── helpers ───────────────────────────────────────────────────────────────

## 一个全 1 的 32³ 块（SOLID 可编码，体积最小）。
func _solid_block(mat: int) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(BLOCK_VOLUME)
	buf.fill(mat)
	return buf


## 从 at 起在 length 字节内数有几个 17 字节子块。
func _count_sub_blocks(payload: PackedByteArray, at: int, length: int) -> int:
	var pos := at
	var end := at + length
	var n := 0
	while pos < end:
		var sub := QVoxelBlockStream.read_sub_block(payload, pos, end)
		if sub.is_empty():
			break
		n += 1
		pos += int(sub.get("total"))
	return n
