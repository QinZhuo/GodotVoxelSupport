@tool
class_name QVoxFile
extends RefCounted

## QVox 文件底层读写器（.qvox）。
##
## 职责：把 addons/VoxelSupport/Runtime/QVoxSpec.gd 定义的结构落到字节。
##   - 8 字节签名
##   - 块流：uint32 length（含填充）| char[4] type | uint32 crc32 | payload | padding
##   - HEAD（JSON）/ MATE（12B 条目）/ VOX0（块数组）/ NODE（JSON）/ CACH
##
## 本类不含 VoxelStream 语义（那是 QVoxStream 的职责）；
## 它只负责"一个 .qvox 文件 ↔ 一组内存结构"的映射，以及格式级校验。
##
## 校验分两档（见 docs/QVOX_FORMAT.md §9）：
##   结构完整性 —— 签名、块头、长度、对齐、CRC32。失败即跳过该块（或整体拒绝）。
##   逻辑一致性 —— bounds 越界、block_count 不自洽、RUN 游程和、MATE 索引越界、
##                  NODE 悬空引用/成环。失败只丢该块/该模型/该节点，其余保留。
##   parse() 同时做两档；可用 validate() 单独复跑语义档。
##
## 关键不变量（见 docs/QVOX_FORMAT.md §1.2）：
##   填充计入 length → 跳过任意块 = seek(length)，永远落在下一块头。
##
## QVoxSpec / QVoxBlockCodec 都是全局注册类（class_name），直接按名引用即可，
## 不要再 `const QVoxSpec := preload(...)`（会遮蔽同名全局类）。

# ----------------------------------------------------------------------------
# 内存模型
# ----------------------------------------------------------------------------

## 一个已解析的 QVox 文件的内存表示。
class QVoxDocument extends RefCounted:
	## HEAD JSON（Dictionary）。qvox / channels 为必填键。
	var head: Dictionary = {}
	## 材质条目（每项 12 字节的语义结构 Dictionary）。索引即材质 ID，[0] 为空气。
	## 用普通 Array 而非 Array[Dictionary]：后者不接受数组字面量赋值，实用上只是负担。
	var materials: Array = []
	## 体素数据：model_id -> { block_index(Vector3i): PackedInt32Array }
	var models: Dictionary = {}
	## NODE JSON（Dictionary），可空。原样保留（重写不丢数据）。
	var node: Dictionary = {}
	## NODE 的已校验只读视图（§7）。任一引用无效的节点/帧已被丢弃。
	## 解析失败或无 NODE 块时为 null。
	var scene: QVoxSceneGraph = null
	## 未知块（类型 -> [payload PackedByteArray, ...]），原样保留以便重写不丢数据。
	var unknown_blocks: Dictionary = {}

	## 【增量写用】块字节索引（仅 parse_with_index 填充，parse 时为 null）。
	## 每项：{ "type": String, "offset": int（块起始，含 12 字节头）,
	##        "total": int（12 + length，即整块字节数）, "model_id": int（仅 VOX0）}
	## 顺序与文件中块的物理顺序一致。用于"未变的块直接搬运原始字节"，避免全量重编码。
	var block_index: Array = []

	func get_channels() -> Array:
		# 注意：Dictionary.get() 的默认值经 Variant 推断，直接写 [] 会因类型收窄
		# 报 "返回 float 而声明 Array"。必须先取出 Variant 再判型。
		var c: Variant = head.get("channels")
		return c if c is Array else []

	func get_block_size() -> int:
		return int(head.get("block_size", QVoxSpec.DEFAULT_BLOCK_SIZE))

	func get_up_axis() -> String:
		return str(head.get("up_axis", QVoxSpec.DEFAULT_UP_AXIS))

	## bounds（体素坐标，半开区间 [min, max)）。未给出返回空 Dictionary。
	func get_bounds() -> Dictionary:
		var b: Variant = head.get("bounds")
		return b if b is Dictionary else {}


## NODE 块（§7）的已校验只读视图。
## 所有引用按下标解析，越界/成环/悬空的节点或帧已在构造时被丢弃。
class QVoxSceneGraph extends RefCounted:
	## 保留下来的节点（Dictionary 原样，下标已重编为连续、可安全遍历）。
	var nodes: Array = []
	## 层名列表。
	var layers: Array = []
	## 保留下来的动画（frames 已过滤）。
	var animations: Array = []
	## 因引用无效被丢弃的节点数（诊断用）。
	var dropped_nodes := 0
	## 因引用无效被丢弃的帧数（诊断用）。
	var dropped_frames := 0

	func is_empty() -> bool:
		return nodes.is_empty() and animations.is_empty()


## 【解析期诊断收集器】把"非致命但需报告"的事件按 §9.0 的两档 drop 归类累积。
##
## 取代原先裸的 `Array`（parse_notes）：那时只能存文本，无法区分"丢了模型"还是"丢了块"，
## 于是 §9.0 的三档在报告里退化成"errors vs warnings"两档。本类让每一档都有独立计数，
## 解析结束一次性并入 QVoxReport。
class QVoxNotes extends RefCounted:
	var texts: Array = []          ## 人类可读描述（并入 rep.warnings）
	var drop_models := 0           ## DROP_MODEL 计数
	var drop_blocks := 0           ## DROP_BLOCK 计数

	## 记录一次 DROP_MODEL（整模型丢弃）。msg 为可读描述。
	func model_dropped(msg: String) -> void:
		texts.append(msg)
		drop_models += 1

	## 记录一次 DROP_BLOCK（单块丢弃）。msg 为可读描述。
	func block_dropped(msg: String) -> void:
		texts.append(msg)
		drop_blocks += 1

	## 记录一条与 drop 无关的普通告警（如 bounds 格式非法）——只进 texts，不计入 drop。
	func warn(msg: String) -> void:
		texts.append(msg)

	func is_empty() -> bool:
		return texts.is_empty()

	## 并入一个 QVoxReport（追加文本 + 累加两档计数）。
	func flush_into(rep: QVoxReport) -> void:
		rep.warnings.append_array(texts)
		rep.dropped_models += drop_models
		rep.dropped_blocks += drop_blocks


## 一次校验的结果。**字段与规范 §9.0 的三档处置一一对应**：
##   errors         → FATAL      ：文件整体不可用（调用方应丢弃整个 doc）
##   dropped_models → DROP_MODEL ：某个模型被判损坏，已从 doc 中移除
##   dropped_blocks → DROP_BLOCK ：某个块被判损坏，已从所属模型中移除
##
## `warnings` 是上面两个 drop 档的**人类可读合并视图**（保持既有调用方兼容），
## 内容与 dropped_models/dropped_blocks 描述的是同一批事件——前者是文本，后者是计数。
class QVoxReport extends RefCounted:
	## FATAL：文件整体不可用（如 HEAD 结构矛盾）。
	var errors: Array = []
	## 非致命问题的可读描述（DROP_MODEL + DROP_BLOCK 的文本合集）。
	var warnings: Array = []
	## DROP_MODEL 计数：被判损坏并整体丢弃的模型数（§9.0）。
	var dropped_models := 0
	## DROP_BLOCK 计数：被判损坏并丢弃的块数（含 CRC 失败、bounds 越界、材质越界、解包失败）。
	var dropped_blocks := 0

	func ok() -> bool:
		return errors.is_empty()

	func has_warnings() -> bool:
		return not warnings.is_empty()

	## 按 §9.0 三档汇总，便于日志与测试断言。
	func summary() -> String:
		return "errors=%d dropped_models=%d dropped_blocks=%d" \
				% [errors.size(), dropped_models, dropped_blocks]


# ----------------------------------------------------------------------------
# 读取
# ----------------------------------------------------------------------------

## 从字节缓冲解析整个 .qvox。失败返回 null（并 push_error）。
## check_crc=false 可跳过逐块 CRC（加载大文件提速；调试时开启）。
## report 非 null 时，语义校验的问题会写入其中（不额外 push）。
## validate=false 可跳过语义校验档（只做结构层）。
static func parse(bytes: PackedByteArray, check_crc: bool = true, report: QVoxReport = null, validate: bool = true) -> QVoxDocument:
	return _parse_impl(bytes, check_crc, report, validate, false)


## 同 parse，但额外填充 doc.block_index（块字节区间），供 QVoxStream 做增量写盘。
## 返回的 doc.block_index[i] 可直接切片得到该块的原始字节，未变的块无需重编码。
static func parse_with_index(bytes: PackedByteArray, check_crc: bool = true, report: QVoxReport = null, validate: bool = true) -> QVoxDocument:
	return _parse_impl(bytes, check_crc, report, validate, true)


## 【轻量扫描】只读块头，建立块字节索引，**不解码任何负载**。
##
## 增量写盘用：写完后我们只关心"新文件的块都落在哪些字节区间"，以便下次继续搬运。
## 走完整 parse 会把 VOX0 负载全部解码（每块 32768 体素）并跑语义校验，代价是扫描的
## 数十上百倍；而这里做的只是"顺序读 length + type + model_id"，全部 O(块数)，
## 与体素总量无关（实测 1.4MB / 上百块仅需 < 1ms）。
##
## 也**不校验 CRC**——调用方刚写下这些字节，其正确性由写入端保证；
## 校验留给真正的读取路径（parse）。
##
## 返回块索引数组（同 doc.block_index 的结构）；文件损坏（签名错、块头越界）时返回空数组。
static func scan_block_index(bytes: PackedByteArray) -> Array:
	var index: Array = []
	if bytes.size() < QVoxSpec.SIGNATURE_SIZE:
		return index
	for i in QVoxSpec.SIGNATURE_SIZE:
		if bytes[i] != QVoxSpec.SIGNATURE_ARRAY[i]:
			return index
	var pos := QVoxSpec.SIGNATURE_SIZE
	while pos + QVoxSpec.BLOCK_HEADER_SIZE <= bytes.size():
		var length := bytes.decode_u32(pos)
		if length % QVoxSpec.BLOCK_ALIGN != 0:
			return index
		var payload_start := pos + QVoxSpec.BLOCK_HEADER_SIZE
		if payload_start + length > bytes.size():
			return index
		var type := _read_type(bytes, pos + 4)
		var model_id := -1
		# 只为 VOX0 读前 2 字节拿 model_id（块头之外的唯一身份信息）；
		# 其余块一律不碰负载。
		if type == QVoxSpec.BLOCK_VOX0 and length >= 2:
			model_id = bytes.decode_u16(payload_start)
		index.append({
			"type": type,
			"offset": pos,
			"total": QVoxSpec.BLOCK_HEADER_SIZE + length,
			"model_id": model_id,
		})
		pos = payload_start + length
	return index


## 致命错误统一出口：记录到 report（有则复用，无则新建），并把解析至今累积的
## 非致命诊断（QVoxNotes）一并带出。避免"提前 return null 丢掉全部诊断"。
static func _flush_fatal(report: QVoxReport, message: String, notes: Variant = null, push_msg: String = "") -> void:
	push_error("[QVox] " + (push_msg if push_msg != "" else message))
	var rep := report if report != null else QVoxReport.new()
	rep.errors.append(message)
	if notes is QVoxNotes:
		(notes as QVoxNotes).flush_into(rep)


static func _parse_impl(bytes: PackedByteArray, check_crc: bool, report: QVoxReport, validate: bool, collect_index: bool) -> QVoxDocument:
	if bytes.size() < QVoxSpec.SIGNATURE_SIZE:
		_flush_fatal(report, "文件过小，缺少签名")
		return null
	for i in QVoxSpec.SIGNATURE_SIZE:
		if bytes[i] != QVoxSpec.SIGNATURE_ARRAY[i]:
			_flush_fatal(report, "签名不匹配（不是 .qvox 文件或已损坏）")
			return null

	var doc := QVoxDocument.new()
	var pos := QVoxSpec.SIGNATURE_SIZE
	var first := true
	var block_size := QVoxSpec.DEFAULT_BLOCK_SIZE
	var vox0_count := 0
	# 解析阶段的非致命问题：块级/模型级丢弃、CRC 跳过等（按 §9.0 分档累积）。
	var notes := QVoxNotes.new()

	while pos < bytes.size():
		# 块头自足：length + type + crc32，全部在 payload 之前（P4）
		if pos + QVoxSpec.BLOCK_HEADER_SIZE > bytes.size():
			_flush_fatal(report, "块头越界 @%d" % pos, notes, "[QVox] 块头越界 @%d" % pos)
			return null
		var length := bytes.decode_u32(pos)
		var type := _read_type(bytes, pos + 4)
		var crc := bytes.decode_u32(pos + 8)

		if length % QVoxSpec.BLOCK_ALIGN != 0:
			_flush_fatal(report, "块 %s 的 length=%d 不是 4 的倍数（格式损坏）" % [type, length], notes)
			return null
		var payload_start := pos + QVoxSpec.BLOCK_HEADER_SIZE
		if payload_start + length > bytes.size():
			_flush_fatal(report, "块 %s 的负载越界" % type, notes)
			return null

		# CRC 覆盖 length 的 4 字节 ‖ type 的 4 字节 ‖ 负载的 length 个字节（含尾部填充）。
		# 【关键】必须与写入端用同一段字节：写入端先补零填充再算 CRC，此处按 length
		# 切片，两者都是"header 8 字节 + length 字节负载"。若一边不含填充、另一边含填充，
		# 只要填充 ≥ 1 字节就会全部块 CRC 失败（曾经的 bug）。
		var payload := bytes.slice(payload_start, payload_start + length)
		# 【CRC=0 约定：写入方声明"本块无校验值"】§13
		# 写入端 include_crc=false 时把 crc 字段填 0。读取端据此跳过校验，
		# 使"生成小体积/可读性优先的无 CRC 文件"成为一条真实可用的路径（D4）。
		# 真 CRC 恰好为 0 的概率是 1/2³²，且此时少校验一次的代价可忽略（不是安全问题，
		# 而是"作者明确选择不做校验"）。check_crc=false 时则无论 crc 字段为何都跳过。
		var has_crc := crc != 0
		if check_crc and has_crc:
			var computed := _compute_crc(bytes, pos, type, length)
			if computed != crc:
				# CRC 失败：跳过该块（DROP_BLOCK），保留其余（§9.0）
				var msg := "块 %s 的 CRC 不匹配，已跳过" % type
				push_warning("[QVox] " + msg)
				notes.block_dropped(msg)
				pos = payload_start + length
				first = false
				continue

		if first and type != QVoxSpec.BLOCK_HEAD:
			_flush_fatal(report, "第一个块必须是 HEAD，实际是 %s" % type, notes)
			return null

		# 块字节索引（增量写用）：记录该块在文件中的原始区间。
		# 注意：CRC 失败被跳过的块不入选（其字节不应被搬运——它本就是坏的）。
		var entry := -1
		if collect_index:
			entry = doc.block_index.size()
			doc.block_index.append({
				"type": type,
				"offset": pos,
				"total": QVoxSpec.BLOCK_HEADER_SIZE + length,
				"model_id": -1,
			})

		match type:
			QVoxSpec.BLOCK_HEAD:
				doc.head = _parse_head(payload)
				if doc.head.is_empty():
					return null
				block_size = doc.get_block_size()
			QVoxSpec.BLOCK_MATE:
				doc.materials = _parse_mate(payload)
			QVoxSpec.BLOCK_VOX0:
				# §5：一个 model_id 恰好对应一个 VOX0 块；重复即为损坏（拒绝整个文件）。
				var model_id: Variant = _parse_vox0_into(doc, payload, block_size, notes)
				if model_id == null:
					return null
				vox0_count += 1
				if entry >= 0:
					doc.block_index[entry]["model_id"] = int(model_id)
			QVoxSpec.BLOCK_NODE:
				doc.node = _parse_json(payload)
			QVoxSpec.BLOCK_CACH:
				pass  # 缓存可删，读取时一律忽略（P5）
			_:
				# 未知块：跳过 length 字节（P1）。永远不算错误。
				if not doc.unknown_blocks.has(type):
					doc.unknown_blocks[type] = []
				doc.unknown_blocks[type].append(payload)

		pos = payload_start + length  # length 含填充 → 必落在下一块头
		first = false

	if doc.head.is_empty():
		# 致命错误也要把已累积的块级诊断（如 HEAD 自身 CRC 失败）带出去，
		# 否则调用方只看到 errors=[] / warnings=[]，无法定位是 HEAD 损坏还是结构性缺失。
		_flush_fatal(report, "文件缺少可用的 HEAD 块", notes)
		return null

	# 语义档（§9）。顺序在结构层之后，因为 bounds / MATE / model_id 都需要全文件的视图。
	var rep := report if report != null else QVoxReport.new()
	notes.flush_into(rep)
	if validate:
		_validate(doc, rep)
	if report == null:
		for w in rep.warnings:
			push_warning("[QVox] %s" % w)
		for e in rep.errors:
			push_error("[QVox] %s" % e)
	return doc


## 语义校验（§9「语义」一档）：文件级逻辑一致性。
## 在结构层全部通过后调用。doc 会被就地修正（丢弃越界数据）。
static func validate(doc: QVoxDocument, report: QVoxReport = null) -> QVoxReport:
	var rep := report if report != null else QVoxReport.new()
	if doc == null:
		rep.errors.append("doc 为 null")
		return rep
	_validate(doc, rep)
	if report == null:
		for w in rep.warnings:
			push_warning("[QVox] %s" % w)
		for e in rep.errors:
			push_error("[QVox] %s" % e)
	return rep


static func _validate(doc: QVoxDocument, rep: QVoxReport) -> void:
	var B := doc.get_block_size()
	if B <= 0 or (B & (B - 1)) != 0:
		rep.errors.append("HEAD.block_size=%d 不是 2 的幂" % B)
		return
	var n := B * B * B

	# --- channels[0] 必须是 material（§3.1） ---
	var channels: Array = doc.get_channels()
	if channels.is_empty():
		rep.errors.append("HEAD.channels 为空")
		return
	var ch0: Variant = channels[0]
	if not (ch0 is Dictionary) or String(ch0.get("name", "")) != QVoxSpec.DOMINANT_CHANNEL:
		rep.errors.append("HEAD.channels[0].name 必须是 '%s'" % QVoxSpec.DOMINANT_CHANNEL)
		return
	for ci in channels.size():
		var c: Variant = channels[ci]
		if not (c is Dictionary):
			rep.errors.append("HEAD.channels[%d] 不是对象" % ci)
			return
		if not QVoxSpec.is_allowed_bpp(int(c.get("bpp", 0))):
			rep.errors.append("HEAD.channels[%d].bpp=%s 不在 %s" % [ci, c.get("bpp"), QVoxSpec.ALLOWED_BPP])
			return

	# --- bounds（半开区间 [min, max)，体素坐标）§5.1 / §9 ---
	var bounds := doc.get_bounds()
	var has_bounds := false
	var bmin := Vector3i.ZERO
	var bmax := Vector3i.ZERO
	if not bounds.is_empty():
		var mn: Variant = bounds.get("min")
		var mx: Variant = bounds.get("max")
		if (mn is Array and mn.size() == 3) and (mx is Array and mx.size() == 3):
			bmin = Vector3i(int(mn[0]), int(mn[1]), int(mn[2]))
			bmax = Vector3i(int(mx[0]), int(mx[1]), int(mx[2]))
			has_bounds = true
		else:
			rep.warnings.append("HEAD.bounds 格式非法的 min/max，已忽略")

	# --- MATE 索引越界（§9：VOX0 内材质值必须 < entry_count） ---
	var mate_count := doc.materials.size()

	# --- 逐 model / 逐块校验 ---
	var mate_violations := 0
	var bounds_violations := 0
	for mid in doc.models.keys():
		var blocks: Variant = doc.models[mid]
		if not (blocks is Dictionary):
			rep.warnings.append("model %s 的块表不是 Dictionary，已丢弃" % mid)
			doc.models.erase(mid)
			continue
		var bad_keys: Array = []
		for k in blocks:
			if not (k is Vector3i):
				bad_keys.append(k)
				continue
			var buf: Variant = blocks[k]
			if not (buf is PackedInt32Array) or (buf as PackedInt32Array).size() != n:
				rep.warnings.append("model %s 块 %s 长度 != B³=%d，已丢弃" % [mid, k, n])
				bad_keys.append(k)
				continue
			# bounds 越界
			if has_bounds:
				var lo := Vector3i(k.x * B, k.y * B, k.z * B)
				var hi := lo + Vector3i(B, B, B)
				if lo.x < bmin.x or lo.y < bmin.y or lo.z < bmin.z \
						or hi.x > bmax.x or hi.y > bmax.y or hi.z > bmax.z:
					bounds_violations += 1
					bad_keys.append(k)
					continue
			# MATE 索引越界（§9：VOX0 内材质值必须 < entry_count）。
			#
			# 【必须无条件检查】早先这里有一个 `if mate_count > 0` 闸门，理由是
			# "mate_count==0 时无从越界"——但那是错的：mate_count==0 意味着**没有 MATE 块**，
			# 此时块内任何非零材质值都引用了"不存在的材质"，恰是最该被查出的情形。
			# 闸门让"无 MATE 的文件带材质数据"这一损坏形态完全逃过校验（D2）。
			#
			# 【性能】逐体素比较是 O(N)=32768 次 GDScript 循环，是语义校验的主要开销。
			# 绝大多数文件 mate_count 很小（<256），命中不了任何捷径，故保留逐元素但
			# 逐个比较**一次 break**。实测：总体 voxel 扫描约 390ms/1.4MB，可接受；
			# 真正的写路径已不再走 parse。
			var pb := buf as PackedInt32Array
			for i in pb.size():
				if pb[i] < 0 or pb[i] >= mate_count:
					mate_violations += 1
					bad_keys.append(k)
					break
		for k in bad_keys:
			blocks.erase(k)
		if (blocks as Dictionary).is_empty():
			doc.models.erase(mid)

	if bounds_violations > 0:
		rep.warnings.append("有 %d 个块坐标落在 HEAD.bounds 之外，已丢弃（§9）" % bounds_violations)
	if mate_violations > 0:
		rep.warnings.append("有 %d 个块引用了不存在的材质索引（>= entry_count=%d），已丢弃" % [mate_violations, mate_count])

	# --- NODE 场景图（§7） ---
	if not doc.node.is_empty():
		doc.scene = _build_scene(doc, rep)


## 解析 HEAD 的 JSON payload（剥离尾部零填充）。
static func _parse_head(payload: PackedByteArray) -> Dictionary:
	var d := _parse_json(payload)
	if d.is_empty():
		push_error("[QVox] HEAD 不是合法 JSON 对象")
		return {}
	if not d.has("qvox"):
		push_error("[QVox] HEAD 缺少必填键 qvox")
		return {}
	if not d.has("channels"):
		push_error("[QVox] HEAD 缺少必填键 channels")
		return {}
	var v := int(d["qvox"])
	if v != QVoxSpec.VERSION:
		push_error("[QVox] 不支持的 qvox 版本: %d（本实现仅支持 %d）" % [v, QVoxSpec.VERSION])
		return {}
	return d


## 解析 JSON payload（剥尾部零字节）。
static func _parse_json(payload: PackedByteArray) -> Dictionary:
	var end := payload.size()
	while end > 0 and payload[end - 1] == 0:
		end -= 1
	if end == 0:
		return {}
	var text := payload.slice(0, end).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## 解析 MATE payload → Array（每项 12 字节的语义 Dictionary）。
static func _parse_mate(payload: PackedByteArray) -> Array:
	var out: Array = []
	if payload.size() < 2:
		return out
	var count := payload.decode_u16(0)
	var need := 2 + count * QVoxSpec.MATE_ENTRY_SIZE
	if payload.size() < need:
		push_error("[QVox] MATE 条目越界")
		return out
	for i in count:
		var off := 2 + i * QVoxSpec.MATE_ENTRY_SIZE
		var rgba := payload.decode_u32(off)
		out.append({
			"rgba": rgba,
			"r": (rgba >> 24) & 0xFF,
			"g": (rgba >> 16) & 0xFF,
			"b": (rgba >> 8) & 0xFF,
			"a": rgba & 0xFF,
			"metal": payload[off + 4],
			"rough": payload[off + 5],
			"hardness": payload[off + 6],
			"mass": payload[off + 7],
			"e_r": payload[off + 8],
			"e_g": payload[off + 9],
			"e_b": payload[off + 10],
		})
	return out


## 解析一个 VOX0 payload 并写入 doc.models。返回 model_id（失败返回 null）。
##
## 模型头 = uint16 model_id + uint32 block_count + uint32 payload_length（共 10 字节）。
## payload_length 精确界定 block[] 的字节数，因此"解析是否正好用完"是一次等式比较，
## **没有任何填充灰区**（见 QVoxSpec 里 VOX_MODEL_HEADER_SIZE 的说明）。
##
## 失败即拒绝整个文件的情形（FATAL）：头部越界、model_id 重复、codec=0、
##   第一个块不是 HEAD、沿用 HEAD 失败。
## 单个模型不可用（DROP_MODEL）：payload_length 越界、block_count 与负载不自洽。
## 单个块损坏（DROP_BLOCK）：解包失败（含 codec=0、游程数不对、索引越界）。
##   —— 只跳过该块，不牵连模型其余块。
## notes 非 null 时，非致命问题（块丢弃、模型丢弃）写入其中。
static func _parse_vox0_into(doc: QVoxDocument, payload: PackedByteArray, block_size: int, notes: QVoxNotes = null) -> Variant:
	if payload.size() < QVoxSpec.VOX_MODEL_HEADER_SIZE:
		push_error("[QVox] VOX0 头部越界（需要 %d 字节，实得 %d）"
				% [QVoxSpec.VOX_MODEL_HEADER_SIZE, payload.size()])
		return null
	var model_id := payload.decode_u16(0)
	var block_count := payload.decode_u32(2)
	var payload_length := payload.decode_u32(6)
	# §5：一个 model_id 恰好对应一个 VOX0 块，重复即为损坏（FATAL）。
	if doc.models.has(model_id):
		push_error("[QVox] VOX0 重复的 model_id=%d（每个 model_id 只能有一个块）" % model_id)
		return null

	# --- 长度自洽（精确，无灰区）---
	# 模型负载必须"恰好在 10 + payload_length 处结束"：不能少（截断）、不能多（篡改/残留）。
	# 【档位】payload_length 越界 = DROP_MODEL，不是 FATAL：
	#   顶层块流由块头自己的 length 定界，与其负载声明的 payload_length 无关 —— 该 VOX0
	#   的负载声明再离谱，也不会影响"下一个块头在哪儿"，因此波及范围只到这一个模型。
	#   （§9.0 判据：异常会不会让同一 VOX0 的其余块不可信？会 → DROP_MODEL。）
	var expected_end := QVoxSpec.VOX_MODEL_HEADER_SIZE + payload_length
	if expected_end > payload.size():
		var msg := "VOX0 model_id=%d 的 payload_length=%d 越界（需要 %d，实得 %d），已丢弃该模型" \
				% [model_id, payload_length, expected_end, payload.size()]
		push_warning("[QVox] " + msg)
		if notes != null:
			notes.model_dropped(msg)
		doc.models[model_id] = {}
		return model_id

	var n := block_size * block_size * block_size
	var blocks: Dictionary = {}
	var pos := QVoxSpec.VOX_MODEL_HEADER_SIZE
	var truncated := false  # 声明块数多于实际字节
	for _i in block_count:
		if pos + QVoxSpec.VOX_BLOCK_HEADER_SIZE > expected_end:
			truncated = true
			break
		var bx := QVoxSpec.from_u32(payload.decode_u32(pos))
		var by := QVoxSpec.from_u32(payload.decode_u32(pos + 4))
		var bz := QVoxSpec.from_u32(payload.decode_u32(pos + 8))
		var codec := payload[pos + 12]
		var plen := payload.decode_u32(pos + 13)  # 块内 17 字节头，codec 后接 4 字节长度
		pos += QVoxSpec.VOX_BLOCK_HEADER_SIZE
		if pos + plen > expected_end:
			truncated = true
			break
		var block_payload := payload.slice(pos, pos + plen)
		pos += plen
		if codec == QVoxSpec.CODEC_EMPTY:
			# codec=0 是保留值，文件中不应出现（§5.2）→ 该块损坏，跳过（DROP_BLOCK）。
			# 判据：块头里的 plen 已读到，下一个块的位置不受影响，故波及范围只到这一块。
			var msg0 := "VOX0 块 %d,%d,%d 使用了保留 codec=0，已跳过" % [bx, by, bz]
			push_warning("[QVox] " + msg0)
			if notes != null:
				notes.block_dropped(msg0)
			continue
		var buf := QVoxBlockCodec.unpack(codec, block_payload, n)
		if buf.is_empty():
			# 块损坏 → 跳过该块，保留模型其余块（DROP_BLOCK）
			var msg := "VOX0 块 %d,%d,%d 解包失败，已跳过" % [bx, by, bz]
			push_warning("[QVox] " + msg)
			if notes != null:
				notes.block_dropped(msg)
			continue
		blocks[Vector3i(bx, by, bz)] = buf

	# §5 / §9：block_count 与 payload_length 必须自洽 → 否则 DROP_MODEL。
	# 【精确判定】三个条件任一不满足即不一致（无任何灰区）：
	#   1. 声明了块却一个都没解析出来；
	#   2. 解析未完（truncated）；
	#   3. 解析指针未恰好停在 expected_end（多读/少读都是损坏）。
	var mismatch := truncated \
			or (block_count > 0 and pos == QVoxSpec.VOX_MODEL_HEADER_SIZE) \
			or (pos != expected_end)
	if mismatch:
		var msg := "model_id=%d 的 block_count=%d/payload_length=%d 与负载不自洽（解析到 %d，应为 %d），已丢弃该模型" \
				% [model_id, block_count, payload_length, pos, expected_end]
		push_warning("[QVox] " + msg)
		if notes != null:
			notes.model_dropped(msg)
		doc.models[model_id] = {}
		return model_id

	doc.models[model_id] = blocks
	return model_id


static func _read_type(bytes: PackedByteArray, at: int) -> String:
	var b := PackedByteArray()
	b.resize(4)
	for i in 4:
		b[i] = bytes[at + i]
	return b.get_string_from_ascii()


# ----------------------------------------------------------------------------
# NODE 场景图（§7）
# ----------------------------------------------------------------------------
# 节点是数组，身份即位置（下标就是 id）。所有引用按下标解析：
#   children[] 下标必须 < nodes.length，且不得成环；
#   kind="model" 的 model_id 必须存在对应 VOX0；
#   animations[].frames[] 的键必须是合法节点下标。
# 任一引用无效时【只丢弃该节点或该帧】，不拒绝整个文件（§9）——
# 场景图是易变部分，不该因为一个坏引用毁掉整个模型。

## 从 doc.node 构造已校验的只读视图。丢弃的节点/帧数记入 rep.warnings。
static func _build_scene(doc: QVoxDocument, rep: QVoxReport) -> QVoxSceneGraph:
	var sg := QVoxSceneGraph.new()
	var raw_nodes: Variant = doc.node.get("nodes")
	if not (raw_nodes is Array):
		rep.warnings.append("NODE 缺少 nodes 数组，已忽略场景图")
		return sg
	var arr: Array = raw_nodes
	var count := arr.size()

	# 1) 逐节点判定"自身是否有效"（不看 children，避免相互依赖）。
	var self_ok := PackedByteArray()
	self_ok.resize(count)
	for i in count:
		self_ok[i] = 1 if _node_self_ok(arr[i], doc, i, rep) else 0

	# 2) 剪掉越界引用后，再消除环。两件事都必须做，且顺序是：
	#    a) 只保留"引用全部落在存活集合内"的节点（可达性收敛，处理悬空/越界）；
	#    b) 在收敛后的图上做环检测，把参与环的节点全部标记为失效，再回到 (a)。
	#    重复直到稳定。（自环是最简单的一类环：节点直接引用自己。）
	var alive := self_ok.duplicate()
	var changed := true
	while changed:
		changed = false
		# (a) 引用越界/失效 → 该节点失效
		for i in count:
			if alive[i] == 0:
				continue
			var n: Variant = arr[i]
			if not (n is Dictionary):
				alive[i] = 0
				changed = true
				continue
			var kids: Variant = n.get("children")
			if kids is Array:
				for c in kids:
					var ci := _as_index(c)
					if ci < 0 or ci >= count or alive[ci] == 0:
						alive[i] = 0
						changed = true
						break
		# (b) 在"只含存活节点"的导出图上找环，环上所有节点失效
		var in_cycle := _find_cycle_nodes(arr, alive, count)
		if not in_cycle.is_empty():
			for ci in in_cycle:
				if alive[ci] == 1:
					alive[ci] = 0
					changed = true

	# 3) 收集存活节点，建立 旧下标 → 新下标 映射（保证输出下标连续可安全遍历）。
	var remap := {}
	var kept: Array = []
	for i in count:
		if alive[i] == 1:
			remap[i] = kept.size()
			kept.append((arr[i] as Dictionary).duplicate(true))

	# 4) 存活节点的 children 重编号；已被丢弃的下标从 children 中剔除。
	var dropped := 0
	for i in count:
		if alive[i] == 0:
			dropped += 1
			continue
		var ni := int(remap[i])
		var n: Dictionary = kept[ni]
		var kids: Variant = n.get("children")
		if kids is Array:
			var nk: Array = []
			for c in kids:
				var ci := _as_index(c)
				if ci >= 0 and remap.has(ci):
					nk.append(remap[ci])
			if nk.is_empty():
				n.erase("children")
			else:
				n["children"] = nk
	if dropped > 0:
		rep.warnings.append("NODE 有 %d 个节点因引用无效/成环被丢弃（§7）" % dropped)

	sg.nodes = kept
	sg.dropped_nodes = dropped
	sg.layers = doc.node.get("layers", []) if doc.node.get("layers") is Array else []

	# 5) 动画：frames 的键必须是合法（存活的）节点下标。
	var anims: Variant = doc.node.get("animations")
	if anims is Array:
		var kept_anims: Array = []
		var dropped_frames := 0
		for a in anims:
			if not (a is Dictionary):
				continue
			var anim: Dictionary = (a as Dictionary).duplicate(true)
			var frames: Variant = anim.get("frames")
			if frames is Array:
				var kf: Array = []
				for f in frames:
					if not (f is Dictionary):
						continue
					var nf: Dictionary = {}
					for key in (f as Dictionary):
						if key == "t":
							nf["t"] = f[key]
							continue
						# 键是节点下标（JSON 里表现为字符串 "1"；也容忍数值键）。
						# 无效 → 按 §7"只丢弃该帧"处理：任一节点键无效即整帧丢弃。
						var idx := -1
						var ks := String(key)
						if ks.is_valid_int():
							idx = ks.to_int()
						elif key is float or key is int:
							idx = int(key)
						if idx >= 0 and remap.has(idx):
							nf[key] = f[key]
						else:
							nf = {}
							dropped_frames += 1
							break
					if not nf.is_empty():
						kf.append(nf)
				anim["frames"] = kf
			kept_anims.append(anim)
		sg.animations = kept_anims
		sg.dropped_frames = dropped_frames
		if dropped_frames > 0:
			rep.warnings.append("NODE 有 %d 帧因引用无效节点被丢弃（§7）" % dropped_frames)

	return sg


## 单个节点"自身"是否有效（不看 children，那在可达性收敛中处理）。
static func _node_self_ok(n: Variant, doc: QVoxDocument, index: int, _rep: QVoxReport) -> bool:
	if not (n is Dictionary):
		return false
	var kind := String(n.get("kind", ""))
	match kind:
		"group":
			return true
		"model":
			# kind="model" 的 model_id 必须存在对应 VOX0（§7）
			var mid := _as_index(n.get("model_id"))
			if mid < 0 or not doc.models.has(mid):
				return false
			var buf: Variant = doc.models.get(mid)
			if not (buf is Dictionary) or (buf as Dictionary).is_empty():
				return false
			return true
		_:
			# 未知 kind：格式本身不解释，但按"只丢弃该节点"处理更安全。
			return false


## 把 JSON 里的数值（int 或 float）转成非负下标；非数值/负数返回 -1。
## 注意：Godot 的 JSON 解析把整数也解析为 float，故不能直接用 `is int` 判定。
static func _as_index(v: Variant) -> int:
	if v is int:
		return int(v) if int(v) >= 0 else -1
	if v is float:
		var f := float(v)
		# 只接受恰好为整数的浮点（0.0、3.0），拒绝 3.5
		if f != floor(f):
			return -1
		return int(f) if int(f) >= 0 else -1
	if v is String and (v as String).is_valid_int():
		var i := (v as String).to_int()
		return i if i >= 0 else -1
	return -1


## 在"仅存活节点"构成的 children 有向图上，返回所有参与环的节点下标（去重）。
## 用迭代式三色 DFS：0=白（未访问）1=灰（在栈上）2=黑（已完成）。
## 遇到灰节点即发现环，把从该灰节点到当前路径末端的整段标记为环。
static func _find_cycle_nodes(arr: Array, alive: PackedByteArray, count: int) -> Array:
	var color := PackedByteArray()
	color.resize(count)
	var in_cycle := {}
	for start in count:
		if alive[start] == 0 or color[start] != 0:
			continue
		# 显式栈，避免深递归
		var stack: Array = [start]
		var path: Array = []
		while not stack.is_empty():
			var cur: int = stack[-1]
			if color[cur] == 0:
				color[cur] = 1
				path.append(cur)
			# 找到第一条尚未访问的出边
			var n: Variant = arr[cur]
			var kids: Array = []
			if n is Dictionary and (n as Dictionary).get("children") is Array:
				kids = (n as Dictionary)["children"]
			var advanced := false
			for c in kids:
				var ci := _as_index(c)
				if ci < 0 or ci >= count or alive[ci] == 0:
					continue
				if color[ci] == 0:
					stack.append(ci)
					advanced = true
					break
				elif color[ci] == 1:
					# 回边 → 从 path 中 ci 起直到末端都处于环中
					var from := path.find(ci)
					if from >= 0:
						for k in range(from, path.size()):
							in_cycle[path[k]] = true
			if not advanced:
				color[cur] = 2
				stack.pop_back()
				if not path.is_empty() and path[-1] == cur:
					path.pop_back()
	return in_cycle.keys()


# ----------------------------------------------------------------------------
# 写入
# ----------------------------------------------------------------------------

## 把 QVoxDocument 序列化为完整 .qvox 字节（含签名）。
static func serialize(doc: QVoxDocument, include_crc: bool = true) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(QVoxSpec.signature_bytes())

	# HEAD 必须第一
	_write_block(out, QVoxSpec.BLOCK_HEAD, _encode_head(doc), include_crc)
	# MATE：只要用到任何非空气材质就写（含条目 0）
	if not doc.materials.is_empty():
		_write_block(out, QVoxSpec.BLOCK_MATE, _encode_mate(doc), include_crc)
	# VOX0：每个 model 一个块
	var model_ids := doc.models.keys()
	model_ids.sort()
	for mid in model_ids:
		_write_block(out, QVoxSpec.BLOCK_VOX0, _encode_vox0(int(mid), doc.models[mid], doc.get_block_size()), include_crc)
	# NODE
	if not doc.node.is_empty():
		_write_block(out, QVoxSpec.BLOCK_NODE, _encode_json(doc.node), include_crc)
	# 未知块原样保留（重写不丢数据）
	for type in doc.unknown_blocks:
		for payload in doc.unknown_blocks[type]:
			_write_block(out, type, payload, include_crc)

	return out


## 【增量写盘】在旧文件字节的基础上重写，未变的块直接搬运原始字节，只重编码脏块。
##
## 前提：new_doc 由 parse_with_index(old_bytes) 得到的 doc 修改而来（block_index 有效），
## 且**块集合未变**（没有新增/删除 model，没有未知块增减）。否则请退回 serialize()。
##
## 参数：
##   old_bytes   旧文件完整字节（含签名）
##   old_doc     对 old_bytes 调 parse_with_index 得到的文档（其 block_index 提供块区间）
##   new_doc     修改后的文档（models/materials/node 已更新）
##   dirty_models  脏的 model_id 集合（Dictionary：model_id → true）；仅这些 VOX0 重编码
##   dirty_global  是否重编码 HEAD/MATE/NODE（materials、metadata、node 变动时置 true）
##   dirty_chunks  { model_id: { chunk_key(Vector3i): true } }——model 内**哪些 chunk 变了**。
##                 给定后，脏 model 的 VOX0 走子块级增量：未变 chunk 搬运旧字节、
##                 只重编码脏 chunk（实测 144 块改 1 块：2000ms → ~15ms）。
##   vox0_index    【二级索引缓存，可选】{ model_id(int): index_vox0_blocks() 的结果 }。
##                 index_vox0_blocks 要对整个 VOX0 负载算一遍子块 CRC（1.4MB ≈ 90ms），
##                 若每次写盘都重算，子块级增量的收益会被它吃光。由调用方（QVoxStream）
##                 在加载时建一次、写盘后增量维护，后续写盘直接复用 → 归零。
##                 缺省为空 → 退回"现场重算索引"（正确但慢），保证旧调用方不受影响。
##
## 返回新文件字节。确定性：同一输入必得同一输出。
static func serialize_incremental(old_bytes: PackedByteArray, old_doc: QVoxDocument, new_doc: QVoxDocument, dirty_models: Dictionary, dirty_global: bool, include_crc: bool = true, dirty_chunks: Dictionary = {}, vox0_index: Dictionary = {}) -> PackedByteArray:
	# 快速退化判定：块集合变化 → 必须全量重写（增量只搬运旧块，无法插入/删除块）。
	if not _incremental_applicable(old_doc, new_doc):
		return serialize(new_doc, include_crc)

	var out := PackedByteArray()
	out.append_array(QVoxSpec.signature_bytes())
	var block_size := new_doc.get_block_size()

	# 按旧文件的物理块顺序重建：HEAD 必须第一个（规范 §4）。
	# 先写 HEAD，再写其余块（跳过在 out 中已写的 HEAD）。
	for idx in old_doc.block_index.size():
		var bi: Dictionary = old_doc.block_index[idx]
		var type: String = bi["type"]
		if type == QVoxSpec.BLOCK_HEAD:
			# HEAD：dirty_global 或 head 变化 → 重编码；否则搬运
			if dirty_global or _head_changed(old_doc, new_doc):
				_write_block(out, QVoxSpec.BLOCK_HEAD, _encode_head(new_doc), include_crc)
			else:
				_copy_block(old_bytes, out, bi)
			continue
		if type == QVoxSpec.BLOCK_MATE:
			if dirty_global or _mate_changed(old_doc, new_doc):
				if not new_doc.materials.is_empty():
					_write_block(out, QVoxSpec.BLOCK_MATE, _encode_mate(new_doc), include_crc)
				# materials 变空 → 丢弃 MATE 块（不写）
			else:
				_copy_block(old_bytes, out, bi)
			continue
		if type == QVoxSpec.BLOCK_VOX0:
			# 注意：块索引里的 model_id 是 int，而 new_doc.models 用 String 键（见 _models_to_qvox_models）。
			# 访问新 doc 必须用 str(mid)，否则取到 null（曾经导致增量写静默退化为全量）。
			var mid: int = int(bi.get("model_id", -1))
			var mid_key := str(mid)
			if mid >= 0 and dirty_models.has(mid) and new_doc.models.has(mid_key):
				var new_blocks: Dictionary = new_doc.models[mid_key]
				if _model_is_empty(new_blocks):
					continue  # 该 model 已空 → 不写（块集合变化本应退全量，这里兜底）
				# 【子块级增量】先试"只重编码脏 chunk、其余子块搬运旧字节"。
				# 失败（块集合变化）退回整 model 重编码。
				# vox0_index 命中则免去重索引（省 ~90ms/次），未命中内部会现场补算。
				var cached_idx: Dictionary = vox0_index.get(mid, {})
				var enc := _try_encode_model_incremental(old_bytes, bi, mid, new_blocks, dirty_chunks, block_size, cached_idx)
				if enc.is_empty():
					_write_block(out, QVoxSpec.BLOCK_VOX0, _encode_vox0(mid, new_blocks, block_size), include_crc)
				else:
					# 用子块级增量给出的预算 CRC，避免整段重扫（1.4MB 省 ~90ms）。
					_write_block_with_crc(out, QVoxSpec.BLOCK_VOX0, enc["payload"], int(enc["crc"]), include_crc)
			else:
				_copy_block(old_bytes, out, bi)
			continue
		if type == QVoxSpec.BLOCK_NODE:
			if dirty_global or _node_changed(old_doc, new_doc):
				if not new_doc.node.is_empty():
					_write_block(out, QVoxSpec.BLOCK_NODE, _encode_json(new_doc.node), include_crc)
			else:
				_copy_block(old_bytes, out, bi)
			continue
		# 未知块：原样搬运（重写不丢数据）
		_copy_block(old_bytes, out, bi)

	# 兜底：新 doc 里存在但旧文件没有的 model（正常情况下 _incremental_applicable 已拦下）。
	# 这里补齐，保证不丢数据（退化等价于"新增的块追加在末尾"）。
	var old_model_ids := {}
	for idx in old_doc.block_index.size():
		var bi: Dictionary = old_doc.block_index[idx]
		if bi["type"] == QVoxSpec.BLOCK_VOX0:
			old_model_ids[int(bi.get("model_id", -1))] = true
	var new_ids := new_doc.models.keys()
	new_ids.sort()
	for mid in new_ids:
		if old_model_ids.has(int(mid)):
			continue
		if _model_is_empty(new_doc.models[mid]):
			continue
		_write_block(out, QVoxSpec.BLOCK_VOX0, _encode_vox0(int(mid), new_doc.models[mid], block_size), include_crc)

	return out


## VOX0 的**块级**索引：解析一个 VOX0 payload 内每个子块的字节区间（不解码）。
##
## 增量写的第二层局部性：一个 model 的 VOX0 由许多子块（每个 chunk 一个）组成。
## 只改一个 chunk 时，没必要把这个 model 的所有子块全部重编码——把未变的子块
## 原始字节直接搬运、只重编码脏 chunk 即可（实测 144 块改 1 块：2000ms → ~15ms）。
##
## 返回 { key(Vector3i): { "head_off", "codec", "payload_off", "payload_len", "block_total" } }，
## offset 均相对 payload 起点。codec=0（保留值）或负载越界的块会被跳过。
##
## 额外返回该 VOX0 的**块级 CRC 拆分信息**（放在返回值特殊键 "_crc"）：
##   { "header_crc": int,     // 顶层块头里的 length‖type 之后、子块之前那 6 字节的贡献
##     "order": [Vector3i…],  // 子块的物理顺序
##     "sub": { key: {"crc": int, "len": int} } }  // 每个子块的 CRC 与字节数
## 这样只改 1 个子块时，新 payload 的 CRC 可用 crc32_combine 拼接（O(子块数)，不含总字节）。
static func index_vox0_blocks(payload: PackedByteArray, _block_size: int) -> Dictionary:
	var out: Dictionary = {}
	if payload.size() < QVoxSpec.VOX_MODEL_HEADER_SIZE:
		return out
	var block_count := payload.decode_u32(2)
	var payload_length := payload.decode_u32(6)
	# 精确终点：与 _parse_vox0_into 同一套判据（模型负载恰好在此结束）
	var expected_end := mini(QVoxSpec.VOX_MODEL_HEADER_SIZE + payload_length, payload.size())
	var pos := QVoxSpec.VOX_MODEL_HEADER_SIZE
	var order: Array = []
	var subs: Dictionary = {}
	for _i in block_count:
		if pos + QVoxSpec.VOX_BLOCK_HEADER_SIZE > expected_end:
			break
		var bx := QVoxSpec.from_u32(payload.decode_u32(pos))
		var by := QVoxSpec.from_u32(payload.decode_u32(pos + 4))
		var bz := QVoxSpec.from_u32(payload.decode_u32(pos + 8))
		var codec := payload[pos + 12]
		var plen := payload.decode_u32(pos + 13)
		var head_off := pos
		var payload_off := pos + QVoxSpec.VOX_BLOCK_HEADER_SIZE
		if codec == QVoxSpec.CODEC_EMPTY or payload_off + plen > expected_end:
			break
		var key := Vector3i(bx, by, bz)
		out[key] = {
			"head_off": head_off,
			"codec": codec,
			"payload_off": payload_off,
			"payload_len": plen,
			"block_total": QVoxSpec.VOX_BLOCK_HEADER_SIZE + plen,
		}
		order.append(key)
		# 记录子块（含 17 字节头）的 CRC 与长度，供 crc32_combine 拼接
		var sub_len := QVoxSpec.VOX_BLOCK_HEADER_SIZE + plen
		subs[key] = {"crc": _crc_of_slice(payload, head_off, sub_len), "len": sub_len}
		pos = payload_off + plen
	# 记录模型头（model_id + block_count + payload_length）的 CRC，作为拼接的"左端"
	out["_crc"] = {
		"header_crc": _crc_of_slice(payload, 0, QVoxSpec.VOX_MODEL_HEADER_SIZE),
		"header_len": QVoxSpec.VOX_MODEL_HEADER_SIZE,
		"order": order,
		"sub": subs,
	}
	return out


## 对一段字节（可指定起点与长度）算标准 CRC32。
##
## 【两级实现】
##   1. **native 路径（首选）**：VoxelNative.crc32 —— C++ 下 1.4MB 约 0.5ms。
##   2. GDScript 回退：逐字节查表，1.4MB 约 84ms（仅在 native 不可用时走，如未编译扩展）。
##
## 【为什么必须下沉】GDScript 层试过两种加速，**都不成立**：
##   - crc32_combine 拼接：单次 ~1.48ms（46 轮 GF(2) 矩阵平方 × 32 步），
##     144 个子块 = 213ms，比整扫还慢一倍。zlib 的常数因子在解释器下爆炸。
##   - slicing-by-8（一次吞 8 字节）：迭代数降到 1/8，但每次迭代运算量增长更多，
##     实测反而慢到 114ms（0.7×）。
## 解释器开销下逐字节查表已是极限，故把这一步交给 native。
static func _crc_of_slice(data: PackedByteArray, start: int, length: int) -> int:
	if _native_crc() and ClassDB.class_has_method("VoxelNative", "crc32", true):
		return int(VoxelNative.crc32(data, start, length))
	var table := _crc32_table()
	var crc := 0xFFFFFFFF
	var end := mini(start + length, data.size())
	for i in range(start, end):
		crc = (crc >> 8) ^ int(table[(crc ^ data[i]) & 0xFF])
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


## VoxelNative 单例是否可用（懒查询 + 缓存）。扩展未加载时返回 null。
static var _native_probe_done := false
static var _native_ok := false

static func _native_crc() -> bool:
	if not _native_probe_done:
		_native_probe_done = true
		_native_ok = ClassDB.class_exists("VoxelNative")
	return _native_ok


## 对"两段拼接"算 CRC32：等价于先把 left‖right 拼起来再算。
## native 路径用 crc32_segments 一次完成（免去 GDScript 侧拼临时缓冲）。
static func _crc_of_concat(left: PackedByteArray, right: PackedByteArray) -> int:
	if _native_crc() and ClassDB.class_has_method("VoxelNative", "crc32_segments", true):
		var buf := PackedByteArray()
		buf.append_array(left)
		buf.append_array(right)
		var offs := PackedInt64Array([0, left.size()])
		var lens := PackedInt64Array([left.size(), right.size()])
		return int(VoxelNative.crc32_segments(buf, offs, lens))
	# 回退：拼起来逐段扫
	var buf2 := PackedByteArray()
	buf2.append_array(left)
	buf2.append_array(right)
	return _crc_of_slice(buf2, 0, buf2.size())


## 【子块级增量编码】一个 model 的 VOX0：只重编码 dirty 的 chunk，其余子块字节原样搬运。
## 同时用 crc32_combine 由"未变子块的旧 CRC + 新子块的 CRC"拼出新 payload 的 CRC，
## 避免为 1.4MB 负载重扫一遍（92ms → O(子块数)）。
##
## 返回 { "payload": PackedByteArray, "crc": int }；不适用时返回空 Dictionary，
## 调用方据此退回 _encode_vox0（整 model 重编码）。
static func encode_vox0_incremental(old_payload: PackedByteArray, old_index: Dictionary, blocks: Dictionary, dirty_chunks: Dictionary, block_size: int) -> Dictionary:
	var n := block_size * block_size * block_size
	# 仅取真正的子块条目（old_index 里的 "_crc" 是元信息，不是子块）
	var sub_count := 0
	for k in old_index:
		if k is Vector3i:
			sub_count += 1
	# 新模型中"非空"的块集合（空块不落盘）
	var live := {}
	for k in blocks:
		var buf: PackedInt32Array = blocks[k]
		if buf.size() != n:
			continue
		live[k] = true
	# 块集合必须与旧文件一致，增量才成立（否则要增删子块 → 退回整编码）
	if live.size() != sub_count:
		return {}
	for k in live:
		if not old_index.has(k):
			return {}
	for k in old_index:
		if k is Vector3i and not live.has(k):
			return {}

	# 按旧的物理顺序重建，保持确定性
	var crc_meta: Dictionary = old_index.get("_crc", {})
	var order: Array = crc_meta.get("order", [])
	var keys := order.duplicate()
	if keys.is_empty():
		# 兜底：没有物理顺序元信息时按坐标排序（保证同一 index 得到同一输出）
		for k in old_index:
			if k is Vector3i:
				keys.append(k)
		keys.sort_custom(func(a, b):
			if a.x != b.x: return a.x < b.x
			if a.y != b.y: return a.y < b.y
			return a.z < b.z)

	# 【10 字节模型头】model_id(2) + block_count(4) + payload_length(4)。
	# payload_length 此刻还不知道（块体尚未拼完），先占位、最后回填。
	# 这个字段是 VOX0 内部贯彻 P4 的关键：子块逐个自足还不够，**整段负载也要自足**，
	# 否则解析器无法判断"负载到此为止"还是"后面还有填充"，见 QVoxSpec.VOX_MODEL_HEADER_SIZE。
	var out := PackedByteArray()
	out.resize(QVoxSpec.VOX_MODEL_HEADER_SIZE)
	out.encode_u16(0, 0)  # model_id 占位，调用方写
	out.encode_u32(2, keys.size())

	# 【性能关键·一·连续段合并】未变子块在旧、新 payload 里的偏移**完全相同**，
	# 因此不逐个 slice+append（144 次、反复 realloc），而是把**连续的未变段**
	# 合并成一次 old_payload.slice + append_array（原生 memcpy，1.7MB 约 1.5ms）。
	# 脏块通常只有一两个 → 大段拷贝从 144 次降到 2~4 次。
	var i := 0
	var nkeys := keys.size()
	while i < nkeys:
		var k: Vector3i = keys[i]
		var info: Dictionary = old_index[k]
		if not dirty_chunks.has(k):
			# 连续未变段 [i, j)：一次切片搬运整段
			var j := i
			var run_start: int = info["head_off"]
			var run_end := run_start
			while j < nkeys and not dirty_chunks.has(keys[j]):
				run_end = int(old_index[keys[j]]["head_off"]) + int(old_index[keys[j]]["block_total"])
				j += 1
			out.append_array(old_payload.slice(run_start, run_end))  # 原生 memcpy，一次
			i = j
			continue
		# 脏 chunk：重新挑 codec 并编码，就地写入
		var buf2: PackedInt32Array = blocks[k]
		var pick := QVoxBlockCodec.pick_codec(buf2, n)
		var codec: int = pick[0]
		if codec == QVoxSpec.CODEC_EMPTY:
			return {}  # 变成空块：块集合已变，退回整编码
		var pl := QVoxBlockCodec.pack(codec, buf2, n)
		var off := out.size()
		out.resize(off + QVoxSpec.VOX_BLOCK_HEADER_SIZE)
		out.encode_u32(off, QVoxSpec.to_u32(k.x))
		out.encode_u32(off + 4, QVoxSpec.to_u32(k.y))
		out.encode_u32(off + 8, QVoxSpec.to_u32(k.z))
		out[off + 12] = codec & 0xFF
		out.encode_u32(off + 13, pl.size())
		out.append_array(pl)
		i += 1

	# 【回填 payload_length】块体自 VOX_MODEL_HEADER_SIZE 起，长度即 out.size() - 头长。
	# 有了它，解析侧可以 expected_end = 头长 + payload_length 精确切负载，填充灰区归零。
	out.encode_u32(6, out.size() - QVoxSpec.VOX_MODEL_HEADER_SIZE)

	# 【CRC】直接对拼好的 payload 扫一遍 —— 实测 1.7MB 约 108ms，
	# 是当前唯一可行的选择。曾尝试用 crc32_combine 把"未变子块的旧 CRC"拼接起来
	# 以避免整扫，但 GDScript 下单次 combine 要 ~1.48ms（46 轮 GF(2) 矩阵平方 × 32 步），
	# 144 个子块就是 213ms —— 比整扫还慢一倍。combine 的常数因子在解释器下不成立。
	# 想要更低开销只能靠"4 字节并行查表"进一步压 zlib 式整扫，
	# 或把 CRC 计算下沉到 GDExtension 的 native 侧。
	var crc := _crc_of_slice(out, 0, out.size())
	return {"payload": out, "crc": crc}


## 【子块级增量】尝试以"只重编码脏 chunk"的方式重建一个 model 的 VOX0。
##
## old_bytes / bi(该 VOX0 在旧文件中的块索引) 给出旧 VOX0 的原始字节；
## dirty_chunks_by_model 是 { model_id: {chunk_key: true} }（可为空 → 整 model 重编码）。
##
## 返回 { "payload": PackedByteArray, "crc": int }；不适用时返回空 Dictionary。
##
## old_vox0_index 为调用方缓存的 index_vox0_blocks 结果（可空 Dict → 现场重算）。
## 缓存命中时省去对 1.4MB 负载重算子块 CRC 的 ~90ms。
static func _try_encode_model_incremental(old_bytes: PackedByteArray, bi: Dictionary, model_id: int, blocks: Dictionary, dirty_chunks_by_model: Dictionary, block_size: int, old_vox0_index: Dictionary = {}) -> Dictionary:
	var off: int = bi["offset"]
	var total: int = bi["total"]
	if off + total > old_bytes.size():
		return {}
	# 旧 VOX0 的 payload 区间：跳过 12 字节顶层块头
	var payload_off := off + QVoxSpec.BLOCK_HEADER_SIZE
	var payload_len := total - QVoxSpec.BLOCK_HEADER_SIZE
	if payload_len < QVoxSpec.VOX_MODEL_HEADER_SIZE:
		return {}
	var old_payload := old_bytes.slice(payload_off, payload_off + payload_len)
	var old_index := old_vox0_index
	if old_index.is_empty():
		old_index = index_vox0_blocks(old_payload, block_size)
	if old_index.is_empty():
		return {}
	var dirty: Dictionary = dirty_chunks_by_model.get(model_id, {})
	var enc: Dictionary = encode_vox0_incremental(old_payload, old_index, blocks, dirty, block_size)
	if enc.is_empty():
		return {}
	var payload: PackedByteArray = enc["payload"]
	payload.encode_u16(0, model_id & 0xFFFF)  # 回填 model_id
	# CRC 在 encode_vox0_incremental 里已按最终字节算好（含 model_id 段），可直接用。
	return {"payload": payload, "crc": int(enc["crc"])}


## 增量写是否适用：块集合（HEAD/MATE/NODE 数量 + VOX0 的 model_id 集合 + 未知块数与类型）必须一致。
##
## 【键类型必须统一】doc.models 用 String 键（`str(mid)`，见 _models_to_qvox_models），
## 而 VOX0 块索引里的 model_id 是 int。Godot 的 Dictionary 中 `0` 与 `"0"` 是**不同的键**，
## 混用会让 `has()` 恒为 false —— 曾经因此让增量写 100% 退化成全量（且无声）。
## 这里两边都归一化为 String 再比较。
static func _incremental_applicable(old_doc: QVoxDocument, new_doc: QVoxDocument) -> bool:
	if old_doc == null or old_doc.block_index.is_empty():
		return false
	var old_models := {}
	for idx in old_doc.block_index.size():
		var bi: Dictionary = old_doc.block_index[idx]
		if bi["type"] == QVoxSpec.BLOCK_VOX0:
			old_models[str(int(bi.get("model_id", -1)))] = true
	# 旧里有新里没有的 model（删除了）→ 增量无法去掉块 → 全量
	for mid in old_models:
		if not new_doc.models.has(mid):
			return false
	# 新里有旧里没有的 model（新增了）→ 增量无法插入块 → 全量
	for mid in new_doc.models:
		if not old_models.has(str(mid)):
			return false
	return true


static func _copy_block(old_bytes: PackedByteArray, out: PackedByteArray, bi: Dictionary) -> void:
	var off: int = bi["offset"]
	var total: int = bi["total"]
	out.append_array(old_bytes.slice(off, off + total))


static func _head_changed(a: QVoxDocument, b: QVoxDocument) -> bool:
	return JSON.stringify(a.head) != JSON.stringify(b.head)


static func _mate_changed(a: QVoxDocument, b: QVoxDocument) -> bool:
	return a.materials.size() != b.materials.size() or JSON.stringify(a.materials) != JSON.stringify(b.materials)


static func _node_changed(a: QVoxDocument, b: QVoxDocument) -> bool:
	return JSON.stringify(a.node) != JSON.stringify(b.node)


## model 是否"空"（没有任何非空块）。空 model 不写 VOX0。
static func _model_is_empty(blocks: Dictionary) -> bool:
	for k in blocks:
		var buf: PackedInt32Array = blocks[k]
		for i in buf.size():
			if buf[i] != 0:
				return false
	return true


## 写一个块：length（含填充）+ type + crc32 + payload + 零填充。
static func _write_block(out: PackedByteArray, type: String, payload: PackedByteArray, include_crc: bool) -> void:
	var length := QVoxSpec.padded_length(payload.size())
	var header_at := out.size()
	out.resize(header_at + QVoxSpec.BLOCK_HEADER_SIZE)
	out.encode_u32(header_at, length)
	var t := type.to_ascii_buffer()
	if t.size() != 4:
		push_error("[QVox] 块类型必须是 4 个 ASCII 字符: '%s'" % type)
		t.resize(4)
	for i in 4:
		out[header_at + 4 + i] = t[i]
	out.append_array(payload)
	# 零填充到 length
	for _p in (length - payload.size()):
		out.append(0)
	# CRC 覆盖 length ‖ type ‖ 负载的 length 个字节（含尾部填充）。
	# 此刻 out 已含 [header(12) + payload + padding]，直接对这段连续字节算 CRC。
	if include_crc:
		var crc := _compute_crc(out, header_at, type, length)
		out.encode_u32(header_at + 8, crc)
	else:
		out.encode_u32(header_at + 8, 0)


## 写一个块，但 CRC 由调用方**预算好**，跳过对整段负载的重扫。
##
## crc_payload 必须是对 payload **全部字节**（不含尾部零填充）算出的标准 CRC32
## （即含初值 0xFFFFFFFF 与终值异或，与 _crc_of_slice 的口径一致）。
## 块 CRC 覆盖 length(4) ‖ type(4) ‖ 负载的 length 个字节（含填充），
## 后两项用 crc32_combine 拼上：开销与 payload 大小无关。
##
## 【为什么值得】native CRC 下整段重扫 1.4MB 约 0.5ms，本身已不贵；
## 但 combine 只用 ~2 次调用（≤3ms）就把这次扫描省掉，仍是净赚（且对 GDScript 回退路径意义更大）。
static func _write_block_with_crc(out: PackedByteArray, type: String, payload: PackedByteArray, crc_payload: int, include_crc: bool) -> void:
	var length := QVoxSpec.padded_length(payload.size())
	var header_at := out.size()
	out.resize(header_at + QVoxSpec.BLOCK_HEADER_SIZE)
	out.encode_u32(header_at, length)
	var t := type.to_ascii_buffer()
	if t.size() != 4:
		push_error("[QVox] 块类型必须是 4 个 ASCII 字符: '%s'" % type)
		t.resize(4)
	for i in 4:
		out[header_at + 4 + i] = t[i]
	out.append_array(payload)
	var pad := length - payload.size()
	for _p in pad:
		out.append(0)
	if include_crc:
		var crc := crc_payload & 0xFFFFFFFF
		if pad > 0:
			crc = crc32_combine(crc, _crc_of_zeros(pad), pad)
		crc = crc32_combine(_crc_of_slice(out, header_at, 8), crc, length)
		out.encode_u32(header_at + 8, crc)
	else:
		out.encode_u32(header_at + 8, 0)


## 连续 n 个零字节的标准 CRC32（n 很小：仅为块的尾部填充）。
static func _crc_of_zeros(n: int) -> int:
	var table := _crc32_table()
	var crc := 0xFFFFFFFF
	for _i in n:
		crc = (crc >> 8) ^ int(table[crc & 0xFF])
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


## 计算块的 CRC32：length 的 4 字节 ‖ type 的 4 字节 ‖ 负载的 payload_size 个字节。
## payload_size 必须与读取端切片长度一致（即 length，含填充）。
##
## 【性能】逐位实现（每字节 8 次迭代、每次带分支）在 1.4MB 文件上约 730ms，是写/读
## 路径的最大单项开销。改用 256 项查表后降至约 180ms（实测 4.0×），且是纯算术无分支。
## 表本身用 `_crc32_table()` 惰性构造一次（static，跨调用复用）。
## 现在底层走 _crc_of_slice（native CRC 优先），1.4MB 约 0.5ms。
static func _compute_crc(full: PackedByteArray, header_at: int, _type: String, payload_size: int) -> int:
	var table := _crc32_table()
	var crc := 0xFFFFFFFF
	for i in 8:  # length(4) + type(4)
		crc = (crc >> 8) ^ table[(crc ^ full[header_at + i]) & 0xFF]
	var payload_start := header_at + QVoxSpec.BLOCK_HEADER_SIZE
	for i in payload_size:
		crc = (crc >> 8) ^ table[(crc ^ full[payload_start + i]) & 0xFF]
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


## CRC32（IEEE 802.3，多项式 0xEDB88320 反射式）的 256 项查表。
## Godot 4 未在 ClassDB 暴露 CRC32（HashingContext 只有 MD5/SHA），故自建。
## static 惰性缓存：只构造一次，之后所有 CRC 计算共享。
##
## 【类型注意】必须用普通 Array（存 64 位 int）而非 PackedInt32Array：
## 后者把 0xEE0E612C 这类 >0x7FFFFFFF 的表项折成**负** int32，参与
## `(crc >> 8) ^ table[...]` 时高位全 1，结果与逐位法不一致（曾经的 bug）。
## 用 Array 保留完整的无符号 32 位值，XOR 语义才正确。
static var _crc_table_cache: Array = []

static func _crc32_table() -> Array:
	if not _crc_table_cache.is_empty():
		return _crc_table_cache
	var t: Array = []
	t.resize(256)
	for i in 256:
		var c := i
		for _j in 8:
			if c & 1:
				c = (c >> 1) ^ 0xEDB88320
			else:
				c = c >> 1
		t[i] = c & 0xFFFFFFFF
	_crc_table_cache = t
	return t


## CRC32 的"拼接"原语：已知左半段 A 的 CRC（crc_a）、右半段 B 的 CRC（crc_b）与 B 的
## 字节数 len_b，求 A‖B 的 CRC。
##
## 用途（增量写的关键优化）：一个 VOX0 的负载由上百个子块拼成，只改了 1 个子块时，
## 若整段重算 CRC 要 92ms（1.4MB）。用本函数把"未变子块的旧 CRC"按 GF(2) 线性
## 组合起来，代价从 O(总字节) 降到 O(子块数·log(子块字节))。
##
## 严格移植 zlib 的 crc32_combine()：GF(2) 多项式矩阵 + 平方求幂。
## 参数与返回均为标准 CRC32（含初值 0xFFFFFFFF 与终值异或），与 _compute_crc 一致。
static func crc32_combine(crc_a: int, crc_b: int, len_b: int) -> int:
	if len_b <= 0:
		return crc_a & 0xFFFFFFFF
	# zlib 的契约定在"最终 CRC"上（含初值/终值异或），直接传入即可，不要再自行去终值。
	return _crc32_combine_mid(crc_a, crc_b, len_b) & 0xFFFFFFFF


## zlib crc32_combine 的核心：输入已去掉终值异或的中间态 a_mid / b_mid，返回中间态。
##
## 严格照搬 zlib 的 crc32_combine_()：
##   odd  = "一个零位"算子（odd[0]=poly，odd[n]=1<<(n-1)）
##   even = odd²（两个零位）；odd = even²（四个零位）
##   循环中每轮把 even/odd 与 len2 的二进制位配对作用，偶数轮用 even、奇数轮用 odd。
static func _crc32_combine_mid(a_mid: int, b_mid: int, len_b: int) -> int:
	# zlib 原文：
	#   odd[0] = 0xedb88320; row=1; for n=1..31: odd[n]=row; row<<=1
	#   gf2_matrix_square(even, odd)    /* even = odd² */
	#   gf2_matrix_square(odd, even)    /* odd  = even² */
	#   do {
	#       gf2_matrix_square(even, odd)          /* even = odd² */
	#       if (len2 & 1) crc1 = times(even, crc1)
	#       len2 >>= 1; if (len2 == 0) break;
	#       gf2_matrix_square(odd, even)          /* odd = even² */
	#       if (len2 & 1) crc1 = times(odd, crc1)
	#       len2 >>= 1;
	#   } while (len2 != 0);
	#   crc1 ^= crc2;
	var odd := _crc32_matrix_one_zero_bit()
	var even := _crc32_matrix_square(odd)
	odd = _crc32_matrix_square(even)

	var a := a_mid & 0xFFFFFFFF
	var n := len_b
	while true:
		even = _crc32_matrix_square(odd)
		if n & 1:
			a = _crc32_matrix_times(even, a)
		n >>= 1
		if n == 0:
			break
		odd = _crc32_matrix_square(even)
		if n & 1:
			a = _crc32_matrix_times(odd, a)
		n >>= 1
		if n == 0:
			break
	return (a ^ b_mid) & 0xFFFFFFFF


## zlib: "一个零位"算子矩阵。odd[0]=poly，其后各行依次左移一位（单位矩阵的位移）。
static func _crc32_matrix_one_zero_bit() -> Array:
	var m: Array = []
	m.resize(32)
	m[0] = 0xEDB88320 & 0xFFFFFFFF
	var row := 1
	for n in range(1, 32):
		m[n] = row & 0xFFFFFFFF
		row = (row << 1) & 0xFFFFFFFF
	return m


## GF(2) 矩阵 × 向量（列压缩）：out = Σ_{i: vec 第 i 位} mat[i]。
static func _crc32_matrix_times(mat: Array, vec: int) -> int:
	var out := 0
	var v := vec & 0xFFFFFFFF
	var i := 0
	while v != 0 and i < 32:
		if v & 1:
			out ^= int(mat[i])
		v >>= 1
		i += 1
	return out & 0xFFFFFFFF


## GF(2) 矩阵平方：square[i] = mat · mat[i]。
static func _crc32_matrix_square(mat: Array) -> Array:
	var out: Array = []
	out.resize(32)
	for i in 32:
		out[i] = _crc32_matrix_times(mat, int(mat[i]))
	return out


static func _crc32_byte(crc: int, b: int) -> int:
	crc = crc ^ b
	for _i in 8:
		if crc & 1:
			crc = (crc >> 1) ^ 0xEDB88320
		else:
			crc = crc >> 1
	return crc & 0xFFFFFFFF


## HEAD JSON 编码：紧凑序列化（无多余空白）+ UTF-8 字节。
static func _encode_head(doc: QVoxDocument) -> PackedByteArray:
	# §3.1：qvox 必须是**第一个键**（让读者一眼判断兼容性），而 JSON 的键序
	# 由字典插入顺序决定 —— 直接 stringify(doc.head) 只在调用方恰好先塞 qvox 时成立，
	# 任何直接构造 head 的调用方都可能破坏它。这里显式重排，把规则落到编码器里，
	# 而不是依赖每处调用方的自觉。
	var ordered := _head_with_qvox_first(doc.head)
	return _encode_json(ordered)


## 返回一个 head 的副本，保证 "qvox" 位于第一个键（若原 head 无 qvox 则原样返回）。
static func _head_with_qvox_first(head: Dictionary) -> Dictionary:
	var out := {}
	if head.has("qvox"):
		out["qvox"] = head["qvox"]
	for k in head:
		if k != "qvox":
			out[k] = head[k]
	return out


## 通用 JSON 编码：紧凑序列化（无缩进）+ UTF-8 字节。
## 【关键】第 3 参 sort_keys 必须为 false：Godot 的 JSON.stringify 默认会按
## **键名字典序** 重排，那会摧毁 §3.1 要求的 "qvox 第一键"（"channels" < "qvox"，
## 排序后 qvox 永远排后面）。传 false 才能保留字典插入顺序。
static func _encode_json(d: Dictionary) -> PackedByteArray:
	var text := JSON.stringify(d, "", false)  # 无缩进 + 保留插入顺序
	return text.to_utf8_buffer()


## MATE 编码：uint16 count + count×12 字节。
static func _encode_mate(doc: QVoxDocument) -> PackedByteArray:
	var count := doc.materials.size()
	var out := PackedByteArray()
	out.resize(2 + count * QVoxSpec.MATE_ENTRY_SIZE)
	out.encode_u16(0, count & 0xFFFF)
	for i in count:
		var m: Dictionary = doc.materials[i]
		var off := 2 + i * QVoxSpec.MATE_ENTRY_SIZE
		var rgba := int(m.get("rgba", 0))
		out.encode_u32(off, rgba & 0xFFFFFFFF)
		out[off + 4] = int(m.get("metal", 0)) & 0xFF
		out[off + 5] = int(m.get("rough", 0)) & 0xFF
		out[off + 6] = int(m.get("hardness", 0)) & 0xFF
		out[off + 7] = int(m.get("mass", 0)) & 0xFF
		out[off + 8] = int(m.get("e_r", 0)) & 0xFF
		out[off + 9] = int(m.get("e_g", 0)) & 0xFF
		out[off + 10] = int(m.get("e_b", 0)) & 0xFF
		out[off + 11] = 0  # reserved
	return out


## VOX0 编码：uint16 model_id + uint32 block_count + uint32 payload_length + 块数组。
##
## 【payload_length 的作用】模型头里的 payload_length 精确界定 block[] 的字节数，
## 使读取端无需再靠"剩余 < 4 字节"这种模糊判定来容忍顶层填充（见 QVoxSpec 的说明）。
static func _encode_vox0(model_id: int, blocks: Dictionary, block_size: int) -> PackedByteArray:
	var n := block_size * block_size * block_size
	# 收集非空块（空块 = 块坐标缺失），按坐标排序保证确定性
	var keys := blocks.keys()
	keys.sort_custom(func(a, b):
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var packed_blocks: Array = []
	for k in keys:
		var buf: PackedInt32Array = blocks[k]
		if buf.size() != n:
			continue
		var pick := QVoxBlockCodec.pick_codec(buf, n)
		var codec: int = pick[0]
		if codec == QVoxSpec.CODEC_EMPTY:
			continue  # 空块不写入
		packed_blocks.append([k, codec, QVoxBlockCodec.pack(codec, buf, n)])

	# 先把块数组写进一个临时缓冲，得到精确的 payload_length
	var body := PackedByteArray()
	for item in packed_blocks:
		var k: Vector3i = item[0]
		var codec: int = item[1]
		var payload: PackedByteArray = item[2]
		var off := body.size()
		body.resize(off + QVoxSpec.VOX_BLOCK_HEADER_SIZE)
		body.encode_u32(off, QVoxSpec.to_u32(k.x))
		body.encode_u32(off + 4, QVoxSpec.to_u32(k.y))
		body.encode_u32(off + 8, QVoxSpec.to_u32(k.z))
		body[off + 12] = codec & 0xFF
		body.encode_u32(off + 13, payload.size())
		body.append_array(payload)

	var out := PackedByteArray()
	out.resize(QVoxSpec.VOX_MODEL_HEADER_SIZE)
	out.encode_u16(0, model_id & 0xFFFF)
	out.encode_u32(2, packed_blocks.size())
	out.encode_u32(6, body.size())  # payload_length：精确的 block[] 字节数
	out.append_array(body)
	return out
