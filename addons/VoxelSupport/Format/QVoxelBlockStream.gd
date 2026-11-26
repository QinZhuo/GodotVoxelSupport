@tool
class_name QVoxelBlockStream
extends RefCounted

## QVX 的**块流与各块负载**编解码器：把"字节怎么排"从 QVoxelFile（文件读写编排）里剥出来。
##
## 【为什么分家】纯粹的字节拼装（子块 17 字节头、顶层块 12 字节头、MATE/VXEL/ANIM/CACH 四种
## 负载、JSON 块）占了 QVoxelFile 约三分之一。它们与"文件里有哪些块、顺序如何、增量写要不要
## 搬运"是两件不同的事：前者是**格式布局**（改一次要全仓一致），后者是**读写策略**。
## 混在一个类里时，任何一处布局改动都得跨 1700 行去核对；分家后布局只有本类一份实现，
## QVoxelFile 只剩块流调度。
##
## 布局权威仍是 QVoxelSpec / docs/QVX_FORMAT.md；本类不定义格式，只负责按它拼字节。
## 调用方：QVoxelFile（读写全过程）、Data/QVoxelStream（CACH 索引与 LOD 派生缓存打包）。

# 校验与顶层块框定


## CRC32（标准 IEEE 802.3）—— 统一由原生 VoxelSupportNative 计算，读写两端共用这一处实现。
## 原生下 1.4MB 约 0.5ms；GDScript 逐字节查表要 ~84ms，且 crc32_combine 拼接在解释器下
## 比整扫更慢（实测 1.48ms/次），故不保留兜底 —— 原生库为硬依赖（见 NativeLoader）。
static func slice_crc(data: PackedByteArray, start: int, length: int) -> int:
	return NativeLoader.crc32(data, start, length)


## 一个块的 CRC：覆盖 length(4) ‖ type(4) ‖ 负载的 length 字节（含尾部零填充）。两段不连续
## （中间隔着 crc 字段），交给 crc32_segments 一次算完，免去临时拼接。
static func block_crc(full: PackedByteArray, header_at: int, length: int) -> int:
	return NativeLoader.crc32_segments(full,
			PackedInt64Array([header_at, header_at + QVoxelSpec.BLOCK_HEADER_SIZE]),
			PackedInt64Array([8, length]))


## 写一个顶层块：length（含填充）+ type + crc32 + payload + 零填充。
## include_crc=false 时 crc 字段写 0 —— 格式约定 "0 = 无校验值"（不是"校验通过"），
## 故不写 CRC 的文件仍可被读取，只是不会被验证。
static func write_block(out: PackedByteArray, type: String, payload: PackedByteArray, include_crc: bool) -> void:
	var length := QVoxelSpec.padded_length(payload.size())
	var header_at := out.size()
	out.resize(header_at + QVoxelSpec.BLOCK_HEADER_SIZE)
	out.encode_u32(header_at, length)
	var t := type.to_ascii_buffer()
	if t.size() != 4:
		push_error("[QVX] 块类型必须是 4 个 ASCII 字符: '%s'" % type)
		t.resize(4)
	for i in 4:
		out[header_at + 4 + i] = t[i]
	out.append_array(payload)
	# 零填充到 length（length 是 4 的倍数，读取端靠它定位下一块头）
	for _p in (length - payload.size()):
		out.append(0)
	# CRC 覆盖 length ‖ type ‖ 负载的 length 个字节（含尾部填充）：此刻 out 已含
	# [header(12) + payload + padding]，直接对这段连续字节算。
	if include_crc:
		var crc := block_crc(out, header_at, length)
		out.encode_u32(header_at + 8, crc)
	else:
		out.encode_u32(header_at + 8, 0)


## 读 4 字节块类型（ASCII）。
static func read_type(bytes: PackedByteArray, at: int) -> String:
	var b := PackedByteArray()
	b.resize(4)
	for i in 4:
		b[i] = bytes[at + i]
	return b.get_string_from_ascii()


# VXEL/ANIM 内层子块（17 字节头 + 负载）的**唯一**编解码实现。
# 布局：int32 bx | int32 by | int32 bz | uint8 codec | uint32 payload_length | payload
#
# 【为什么必须收敛到一处】这段布局一旦在多处各写一遍，偏移量（+4 / +8 / +12 / +13）就是
# 手抄的魔法数：漏改一处就会写出读错的文件，而往返自测可能恰好掩盖这种漂移。
# 故读写各收敛为一个函数，偏移只在下面出现一次。


## 追加一个内层子块（17 字节头 + 负载）到 out。
static func write_sub_block(out: PackedByteArray, key: Vector3i, codec: int, payload: PackedByteArray) -> void:
	var off := out.size()
	out.resize(off + QVoxelSpec.VOX_BLOCK_HEADER_SIZE)
	out.encode_u32(off, QVoxelSpec.to_u32(key.x))
	out.encode_u32(off + 4, QVoxelSpec.to_u32(key.y))
	out.encode_u32(off + 8, QVoxelSpec.to_u32(key.z))
	out[off + 12] = codec & 0xFF
	out.encode_u32(off + 13, payload.size())
	out.append_array(payload)


## 从 payload 的 at 处读一个内层子块头，limit 为该段负载的精确终点（不含）。
## 头越界或负载越过 limit（截断）→ 返回空字典，调用方据此判 DROP_MODEL。
static func read_sub_block(payload: PackedByteArray, at: int, limit: int) -> Dictionary:
	var payload_off := at + QVoxelSpec.VOX_BLOCK_HEADER_SIZE
	if payload_off > limit:
		return {}
	var plen := payload.decode_u32(at + 13)
	if payload_off + plen > limit:
		return {}
	return {
		"key": Vector3i(
				QVoxelSpec.from_u32(payload.decode_u32(at)),
				QVoxelSpec.from_u32(payload.decode_u32(at + 4)),
				QVoxelSpec.from_u32(payload.decode_u32(at + 8))),
		"codec": payload[at + 12],
		"payload_off": payload_off,
		"payload_len": plen,
		"total": QVoxelSpec.VOX_BLOCK_HEADER_SIZE + plen,
	}


# JSON 块（HEAD / NODE / CAMR / ANIM 的时序 meta）


## 通用 JSON 解码（剥尾部零填充）。非对象 / 解析失败返回 {}。
static func decode_json(payload: PackedByteArray) -> Dictionary:
	var end := payload.size()
	while end > 0 and payload[end - 1] == 0:
		end -= 1
	if end == 0:
		return {}
	var parsed: Variant = JSON.parse_string(payload.slice(0, end).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


## 通用 JSON 编码：紧凑序列化（无缩进）+ UTF-8 字节。
## 【关键】第 3 参 sort_keys 必须为 false：JSON.stringify 默认按**键名字典序**重排，会摧毁
## "qvox 第一键"（"channels" < "qvox"，排序后 qvx 永远排后面）。传 false 才能保留插入顺序。
static func encode_json(d: Dictionary) -> PackedByteArray:
	return JSON.stringify(d, "", false).to_utf8_buffer()


## HEAD 编码：qvx 必须是**第一个键**（让读者一眼判断兼容性），而 JSON 键序由字典插入顺序决定 ——
## 直接 stringify 只在调用方恰好先塞 qvx 时成立。故在这里显式重排，把规则落到编码器里。
static func encode_head(head: Dictionary) -> PackedByteArray:
	return encode_json(head_with_qvox_first(head))


## 返回一个 head 的副本，保证 "qvox" 位于第一个键（若原 head 无 qvx 则原样返回）。
static func head_with_qvox_first(head: Dictionary) -> Dictionary:
	var out := {}
	if head.has("qvox"):
		out["qvox"] = head["qvox"]
	for k in head:
		if k != "qvox":
			out[k] = head[k]
	return out


# VXEL：一个 model 的块集合


## VXEL 编码：uint16 model_id + uint32 block_count + uint32 payload_length + 块数组。
## payload_length 精确界定 block[] 的字节数，使读取端无需靠"剩余 < 4 字节"这种模糊判定。
static func encode_vxel(model_id: int, blocks: Dictionary, block_size: int) -> PackedByteArray:
	var n := QVoxelSpec.block_volume(block_size)
	# 收集非空块（空块 = 块坐标缺失），按坐标排序保证确定性
	var packed_blocks: Array = []
	for k in QVoxelBlockCodec.sorted_keys(blocks):
		var buf: Variant = blocks[k]
		if not (buf is PackedInt32Array) or (buf as PackedInt32Array).size() != n:
			continue
		var picked := QVoxelBlockCodec.choose_and_pack(buf as PackedInt32Array, n)
		var codec: int = picked.get("codec", QVoxelSpec.CODEC_EMPTY)
		if codec == QVoxelSpec.CODEC_EMPTY:
			continue  # 空块不写入
		packed_blocks.append([k, codec, picked.get("payload", PackedByteArray())])

	# 先把块数组写进一个临时缓冲，得到精确的 payload_length
	var body := PackedByteArray()
	for item in packed_blocks:
		write_sub_block(body, item[0], item[1], item[2])

	var out := PackedByteArray()
	out.resize(QVoxelSpec.VXEL_MODEL_HEADER_SIZE)
	out.encode_u16(0, model_id & 0xFFFF)
	out.encode_u32(2, packed_blocks.size())
	out.encode_u32(6, body.size())  # payload_length：精确的 block[] 字节数
	out.append_array(body)
	return out


# ANIM：一个 model 的帧动画（相对上一帧的块级增量）


## ANIM 编码：uint16 model_id + uint16 frame_count + uint32 payload_length + 时序 meta + 帧数组。
## 【时序 meta】紧跟模型头：uint32 meta_len + meta_len 字节 JSON（fps/loop/tags）。缺省写长度 0。
## 【增量压缩】帧 0 相对空基线写全量（与 VXEL 负载逐字节同构）；帧 k 只写相对帧 k-1 的**块级
## 增量** —— 相同的块不写，变成空的块写 codec=0。于是"一帧的成本 = 相对上一帧改了多少块"。
static func encode_anim(model_id: int, frames: Array, meta: Dictionary, block_size: int) -> PackedByteArray:
	var n := QVoxelSpec.block_volume(block_size)
	var body := PackedByteArray()
	# 时序 meta（JSON）：缺省全不写（P2），meta_len=0 即"全缺省"。
	var meta_dict := anim_meta_json(meta)
	var meta_json := PackedByteArray()
	if not meta_dict.is_empty():
		meta_json = encode_json(meta_dict)
	body.resize(4)
	body.encode_u32(0, meta_json.size())
	body.append_array(meta_json)
	var prev: Dictionary = {}
	var written := 0
	for frame in frames:
		if not (frame is Dictionary):
			continue
		var fd := frame as Dictionary
		var duration := maxi(0, int(fd.get(QVoxelSpec.ANIM_FRAME_DURATION_KEY, 0))) & 0xFFFF
		var cur := QVoxelBlockCodec.table_of(fd.get("blocks", {}))
		var delta := PackedByteArray()
		# 清空：上一帧有、本帧没有的块 → 写 codec=0（ANIM 专有语义）
		var clears: Array = []
		for k in prev:
			if (k is Vector3i) and not cur.has(k):
				clears.append(k)
		# 设置：本帧有、且与上一帧不同的块（相同的块不写，这是增量的收益来源）
		var sets: Array = []
		for k in cur:
			if not (k is Vector3i):
				continue
			var buf: Variant = cur[k]
			if not (buf is PackedInt32Array) or (buf as PackedInt32Array).size() != n:
				continue
			if prev.has(k) and (prev[k] as PackedInt32Array) == buf:
				continue
			sets.append(k)
		clears.sort_custom(QVoxelBlockCodec.key_less)
		sets.sort_custom(QVoxelBlockCodec.key_less)
		for k in clears:
			write_sub_block(delta, k, QVoxelSpec.CODEC_EMPTY, PackedByteArray())
		for k in sets:
			var picked := QVoxelBlockCodec.choose_and_pack(cur[k] as PackedInt32Array, n)
			var codec: int = picked.get("codec", QVoxelSpec.CODEC_EMPTY)
			if codec == QVoxelSpec.CODEC_EMPTY:
				# 全空块本不该出现在块表里（空块 = 坐标缺失）；若出现，按"清空"处理。
				write_sub_block(delta, k, QVoxelSpec.CODEC_EMPTY, PackedByteArray())
				continue
			write_sub_block(delta, k, codec, picked.get("payload", PackedByteArray()))
		# 帧头（6 字节定长）+ 增量负载
		var foff := body.size()
		body.resize(foff + QVoxelSpec.ANIM_FRAME_HEADER_SIZE)
		body.encode_u16(foff, duration)
		body.encode_u32(foff + 2, delta.size())
		body.append_array(delta)
		prev = cur
		written += 1
	var out := PackedByteArray()
	out.resize(QVoxelSpec.ANIM_MODEL_HEADER_SIZE)
	out.encode_u16(0, model_id & 0xFFFF)
	out.encode_u16(2, written & 0xFFFF)
	out.encode_u32(4, body.size())
	out.append_array(body)
	return out


## 时序 meta → JSON 字典（缺省不写，P2）。空字典 = 全缺省（fps=ANIM_FPS_DEFAULT / loop=true / 无 tags）。
## 缺省值一律取 QVoxelSpec.ANIM_* —— 这里的判据是"与缺省不同才写"，若判据的缺省与
## 模型/运行时的缺省不一致，就会每份文件都多背一个冗余键（A6 的成因）。
static func anim_meta_json(meta: Dictionary) -> Dictionary:
	var d := {}
	if meta.is_empty():
		return d
	if int(meta.get("fps", QVoxelSpec.ANIM_FPS_DEFAULT)) != QVoxelSpec.ANIM_FPS_DEFAULT:
		d["fps"] = int(meta["fps"])
	if not bool(meta.get("loop", QVoxelSpec.ANIM_LOOP_DEFAULT)):
		d["loop"] = false
	var tags: Variant = meta.get("tags", [])
	if tags is Array and not (tags as Array).is_empty():
		d["tags"] = tags
	return d


## 时序 meta JSON → 归一化 Dictionary（缺字段补默认，非法忽略）。供 ANIM 解析用。
static func anim_meta_from_json(json: Dictionary) -> Dictionary:
	var d := {"fps": maxi(1, int(json.get("fps", QVoxelSpec.ANIM_FPS_DEFAULT))),
			"loop": bool(json.get("loop", QVoxelSpec.ANIM_LOOP_DEFAULT))}
	var tags: Variant = json.get("tags", [])
	d["tags"] = (tags as Array).duplicate() if tags is Array else []
	return d


# CACH：派生缓存（可删、格式层不解释 kind）


## 把 CACH 条目编码为完整顶层块（含 12 字节块头）并追加到 out。
## 供全量写与增量写追加"变化的条目"共用，故 CACH 的字节布局永远只有一处实现。
static func append_cach_blocks(out: PackedByteArray, entries: Array, include_crc: bool = true) -> void:
	for e in entries:
		if not (e is Dictionary):
			continue
		write_block(out, QVoxelSpec.BLOCK_CACH, encode_cach(e as Dictionary), include_crc)


## CACH 条目 → 负载字节：8 字节定长前置 + source_crc[] + 内容。
static func encode_cach(entry: Dictionary) -> PackedByteArray:
	var kind := String(entry.get("kind", ""))
	var src: Variant = entry.get("source_crc", [])
	var crcs: Array = src if src is Array else []
	var out := PackedByteArray()
	out.resize(QVoxelSpec.CACH_PREFIX_SIZE + crcs.size() * 4)
	var k := kind.to_ascii_buffer()
	if k.size() != 4:
		push_error("[QVX] CACH kind 必须是 4 个 ASCII 字符: '%s'" % kind)
		k.resize(4)
	for i in 4:
		out[i] = k[i]
	out.encode_u16(4, int(entry.get("algo_version", 0)) & 0xFFFF)
	out.encode_u16(6, crcs.size() & 0xFFFF)
	for i in crcs.size():
		out.encode_u32(QVoxelSpec.CACH_PREFIX_SIZE + i * 4, int(crcs[i]) & 0xFFFFFFFF)
	var body: Variant = entry.get("payload", PackedByteArray())
	if body is PackedByteArray:
		out.append_array(body as PackedByteArray)
	return out


## 解析 CACH 负载的**头部**：{ kind, algo_version, source_crc, content_off }，结构非法返回 {}。
## content_off = "前置 + 来源表"之后的字节起点（相对负载起点），即 kind 解释者自己的内容起点。
## **不切出内容字节**：供"只建条目索引、不解码缓存"的调用方使用（QVoxelStream 的 CACH 索引），
## 免得为每个缓存条目复制一份负载。这是 CACH 头部布局的唯一实现。
static func parse_cach_header(payload: PackedByteArray) -> Dictionary:
	if payload.size() < QVoxelSpec.CACH_PREFIX_SIZE:
		return {}
	var source_count := payload.decode_u16(6)
	var need := QVoxelSpec.CACH_PREFIX_SIZE + source_count * 4
	if payload.size() < need:
		return {}
	var source_crc: Array = []
	for i in source_count:
		source_crc.append(payload.decode_u32(QVoxelSpec.CACH_PREFIX_SIZE + i * 4))
	return {
		"kind": read_type(payload, 0),
		"algo_version": payload.decode_u16(4),
		"source_crc": source_crc,
		"content_off": need,
	}


## 解析 CACH 负载 → { kind, algo_version, source_crc, payload }，结构非法返回 null。
## 【长度语义】外层块头的 length 含 0–3 字节尾部零填充，而 CACH 负载段本身没有内部长度
## 字段。因此这里**不剥填充** —— 原样交出"前置 + 来源表之后的全部字节"，由认识该 kind 的
## 写入方按自己的格式定界（"含块尾填充"正是此意）。
static func parse_cach(payload: PackedByteArray) -> Variant:
	var hdr := parse_cach_header(payload)
	if hdr.is_empty():
		return null
	hdr["payload"] = payload.slice(int(hdr["content_off"]))
	return hdr
