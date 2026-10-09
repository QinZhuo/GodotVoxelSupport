@tool
class_name QVoxelFile
extends RefCounted

## QVX 文件底层读写器（.qvx）。
##
## 职责：把 addons/VoxelSupport/Runtime/QVoxelSpec.gd 定义的结构落到字节。
##   - 8 字节签名
##   - 块流：uint32 length（含填充）| char[4] type | uint32 crc32 | payload | padding
##   - HEAD（JSON）/ MATE（12B 条目）/ VOX0（块数组）/ NODE（JSON）/ CACH
##
## 本类不含 VoxelStream 语义（那是 QVoxelStream 的职责）；
## 它只负责"一个 .qvx 文件 ↔ 一组内存结构"的映射，以及格式级校验。
##
## 校验分两档（见 docs/QVX_FORMAT.md §9）：
##   结构完整性 —— 签名、块头、长度、对齐、CRC32。失败即跳过该块（或整体拒绝）。
##   逻辑一致性 —— bounds 越界、block_count 不自洽、RUN 游程和、MATE 索引越界、
##                  NODE 悬空引用/成环。失败只丢该块/该模型/该节点，其余保留。
##   parse() 同时做两档；可用 validate() 单独复跑语义档。
##
## 关键不变量（见 docs/QVX_FORMAT.md §1.2）：
##   填充计入 length → 跳过任意块 = seek(length)，永远落在下一块头。
##
## QVoxelSpec / QVoxelBlockCodec 都是全局注册类（class_name），直接按名引用即可，
## 不要再 `const QVoxelSpec := preload(...)`（会遮蔽同名全局类）。

# ----------------------------------------------------------------------------
# 内存模型
# ----------------------------------------------------------------------------

## 一个已解析的 QVX 文件的内存表示。
class QVoxelDocument extends RefCounted:
	## HEAD JSON（Dictionary）。qvx / channels 为必填键。
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
	var scene: QVoxelSceneGraph = null
	## CACH 块（§6，派生数据：删掉语义为零）。每项：
	##   { "kind": String, "algo_version": int, "source_crc": Array[int]（升序去重）,
	##     "payload": PackedByteArray（定长前置之后的全部字节，含块尾填充）}
	## 顺序即文件中的物理顺序。**格式层不解释任何 kind**（§6：含义由写入方与读者商定），
	## 只做结构切分——把它升为一等块而非"未知块"，是为了让增量写能按块重编码，
	## 而不是把旧 CACH 字节原样搬过去（那会让已失效的缓存永远留在盘上）。
	var cach: Array = []

	## 未内建解析的块（类型 -> [payload PackedByteArray, ...]），**原样保留以便重写不丢数据**。
	## 只装真未知类型（P1：读到不认识的就按 length 跳过并留字节）。CACH 是一等块，不在此。
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
		return int(head.get("block_size", QVoxelSpec.DEFAULT_BLOCK_SIZE))

	func get_up_axis() -> String:
		return str(head.get("up_axis", QVoxelSpec.DEFAULT_UP_AXIS))

	## bounds（体素坐标，半开区间 [min, max)）。未给出返回空 Dictionary。
	func get_bounds() -> Dictionary:
		var b: Variant = head.get("bounds")
		return b if b is Dictionary else {}

	## 全部 model_id（统一为 int，升序）。
	##
	## 【为什么要有这个访问器】`models` 的键可能是 int（解析端与 QVoxelStream 写入端产出的形式），
	## 也可能是 str（调用方手写 doc 时的常见写法）。Godot 里 `0` 与 `"0"` 是不同的键，混用会让
	## `has()`/取值静默落空 —— 历史上正是它让增量写无声退化成全量。把"键类型"这个细节收敛到
	## 本类，读写两侧一律经 model_ids()/model_blocks() 访问，调用方怎么写都不会踩坑。
	func model_ids() -> Array[int]:
		var out: Array[int] = []
		for k in models:
			out.append(int(k))
		out.sort()
		return out

	## 取指定 model_id 的块表（兼容 int / str 两种键；不存在返回 null）。
	func model_blocks(model_id: int) -> Variant:
		if models.has(model_id):
			return models[model_id]
		return models.get(str(model_id))


## NODE 块（§7）的已校验只读视图。
## 节点是**嵌套**的：类型未知 / 非对象的条目已在构造时（连同子树）被丢弃，无下标、无环可言。
class QVoxelSceneGraph extends RefCounted:
	## 保留下来的顶层节点（Dictionary 原样，`children` 仍是嵌套结构，**不做下标重编号**）。
	var nodes: Array = []
	## 相机书签（§5.1）。相机是纯工程数据，不参与几何渲染，故为空时一切照旧。
	var cameras: Array = []
	## 动画**原样透传**（§3）：本层不解释它，故不做任何过滤或补缺省。
	var animations: Array = []
	## 因类型未知 / 非对象被丢弃的节点数（含子树，诊断用）。
	var dropped_nodes := 0

	## 【只算"有几何/有动画"】相机不算：一个"只有相机、还没有模型"的工程
	## 是合法状态（新建即如此），但导入器据此判断"这文件有没有可摆的东西"。
	func is_empty() -> bool:
		return nodes.is_empty() and animations.is_empty()


## 【解析期诊断收集器】把"非致命但需报告"的事件按 §9.0 的两档 drop 归类累积。
##
## 取代原先裸的 `Array`（parse_notes）：那时只能存文本，无法区分"丢了模型"还是"丢了块"，
## 于是 §9.0 的三档在报告里退化成"errors vs warnings"两档。本类让每一档都有独立计数，
## 解析结束一次性并入 QVoxelReport。
class QVoxelNotes extends RefCounted:
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

	## 并入一个 QVoxelReport（追加文本 + 累加两档计数）。
	func flush_into(rep: QVoxelReport) -> void:
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
class QVoxelReport extends RefCounted:
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

## 从字节缓冲解析整个 .qvx。失败返回 null（并 push_error）。
## check_crc=false 可跳过逐块 CRC（加载大文件提速；调试时开启）。
## report 非 null 时，语义校验的问题会写入其中（不额外 push）。
## validate=false 可跳过语义校验档（只做结构层）。
static func parse(bytes: PackedByteArray, check_crc: bool = true, report: QVoxelReport = null, validate: bool = true) -> QVoxelDocument:
	return _parse_impl(bytes, check_crc, report, validate, false)


## 同 parse，但额外填充 doc.block_index（块字节区间），供 QVoxelStream 做增量写盘。
## 返回的 doc.block_index[i] 可直接切片得到该块的原始字节，未变的块无需重编码。
static func parse_with_index(bytes: PackedByteArray, check_crc: bool = true, report: QVoxelReport = null, validate: bool = true) -> QVoxelDocument:
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
	if bytes.size() < QVoxelSpec.SIGNATURE_SIZE:
		return index
	for i in QVoxelSpec.SIGNATURE_SIZE:
		if bytes[i] != QVoxelSpec.SIGNATURE_ARRAY[i]:
			return index
	var pos := QVoxelSpec.SIGNATURE_SIZE
	while pos + QVoxelSpec.BLOCK_HEADER_SIZE <= bytes.size():
		var length := bytes.decode_u32(pos)
		if length % QVoxelSpec.BLOCK_ALIGN != 0:
			return index
		var payload_start := pos + QVoxelSpec.BLOCK_HEADER_SIZE
		if payload_start + length > bytes.size():
			return index
		var type := _read_type(bytes, pos + 4)
		var model_id := -1
		# 只为 VOX0 读前 2 字节拿 model_id（块头之外的唯一身份信息）；
		# 其余块一律不碰负载。
		if type == QVoxelSpec.BLOCK_VOX0 and length >= 2:
			model_id = bytes.decode_u16(payload_start)
		index.append({
			"type": type,
			"offset": pos,
			"total": QVoxelSpec.BLOCK_HEADER_SIZE + length,
			"model_id": model_id,
		})
		pos = payload_start + length
	return index


## 致命错误统一出口：记录到 report（有则复用，无则新建），并把解析至今累积的
## 非致命诊断（QVoxelNotes）一并带出。避免"提前 return null 丢掉全部诊断"。
static func _flush_fatal(report: QVoxelReport, message: String, notes: Variant = null, push_msg: String = "") -> void:
	push_error("[QVX] " + (push_msg if push_msg != "" else message))
	var rep := report if report != null else QVoxelReport.new()
	rep.errors.append(message)
	if notes is QVoxelNotes:
		(notes as QVoxelNotes).flush_into(rep)


static func _parse_impl(bytes: PackedByteArray, check_crc: bool, report: QVoxelReport, validate: bool, collect_index: bool) -> QVoxelDocument:
	if bytes.size() < QVoxelSpec.SIGNATURE_SIZE:
		_flush_fatal(report, "文件过小，缺少签名")
		return null
	for i in QVoxelSpec.SIGNATURE_SIZE:
		if bytes[i] != QVoxelSpec.SIGNATURE_ARRAY[i]:
			_flush_fatal(report, "签名不匹配（不是 .qvx 文件或已损坏）")
			return null

	var doc := QVoxelDocument.new()
	var pos := QVoxelSpec.SIGNATURE_SIZE
	var first := true
	var block_size := QVoxelSpec.DEFAULT_BLOCK_SIZE
	var vox0_count := 0
	# 解析阶段的非致命问题：块级/模型级丢弃、CRC 跳过等（按 §9.0 分档累积）。
	var notes := QVoxelNotes.new()

	while pos < bytes.size():
		# 块头自足：length + type + crc32，全部在 payload 之前（P4）
		if pos + QVoxelSpec.BLOCK_HEADER_SIZE > bytes.size():
			_flush_fatal(report, "块头越界 @%d" % pos, notes, "[QVX] 块头越界 @%d" % pos)
			return null
		var length := bytes.decode_u32(pos)
		var type := _read_type(bytes, pos + 4)
		var crc := bytes.decode_u32(pos + 8)

		if length % QVoxelSpec.BLOCK_ALIGN != 0:
			_flush_fatal(report, "块 %s 的 length=%d 不是 4 的倍数（格式损坏）" % [type, length], notes)
			return null
		var payload_start := pos + QVoxelSpec.BLOCK_HEADER_SIZE
		if payload_start + length > bytes.size():
			_flush_fatal(report, "块 %s 的负载越界" % type, notes)
			return null

		# CRC 覆盖 length 的 4 字节 ‖ type 的 4 字节 ‖ 负载的 length 个字节（含尾部填充）。
		# 【关键】必须与写入端用同一段字节：写入端先补零填充再算 CRC，此处按 length
		# 切片，两者都是"header 8 字节 + length 字节负载"。若一边不含填充、另一边含填充，
		# 只要填充 ≥ 1 字节就会全部块 CRC 失败（曾经的 bug）。
		var payload := bytes.slice(payload_start, payload_start + length)
		# 【CRC=0 约定：写入方声明"本块无校验值"】§10（编码约定·CRC 可关）
		# 写入端 include_crc=false 时把 crc 字段填 0。读取端据此跳过校验，
		# 使"生成小体积/可读性优先的无 CRC 文件"成为一条真实可用的路径（D4）。
		# 真 CRC 恰好为 0 的概率是 1/2³²，且此时少校验一次的代价可忽略（不是安全问题，
		# 而是"作者明确选择不做校验"）。check_crc=false 时则无论 crc 字段为何都跳过。
		var has_crc := crc != 0
		if check_crc and has_crc:
			var computed := _block_crc(bytes, pos, length)
			if computed != crc:
				# CRC 失败：跳过该块（DROP_BLOCK），保留其余（§9.0）
				var msg := "块 %s 的 CRC 不匹配，已跳过" % type
				push_warning("[QVX] " + msg)
				notes.block_dropped(msg)
				pos = payload_start + length
				first = false
				continue

		if first and type != QVoxelSpec.BLOCK_HEAD:
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
				"total": QVoxelSpec.BLOCK_HEADER_SIZE + length,
				"model_id": -1,
			})

		match type:
			QVoxelSpec.BLOCK_HEAD:
				var head_err: Array = [""]
				doc.head = _parse_head(payload, head_err)
				if doc.head.is_empty():
					# HEAD 不合法 = 整体不可用（§9 FATAL）。必须写进报告而不只是 stderr，
					# 否则调用方拿到的 report.errors 为空，会误以为文件没问题。
					_flush_fatal(report, "HEAD 不合法：%s" % head_err[0], notes)
					return null
				# 【能力门】必须在解码任何 VOX0 之前完成：require 声明了本读者处理不了的
				# 块类型、或 channels 数超出当前支持，都属"继续读只会得到错误结果"，
				# 按 §10 拒绝整个文件（而不是静默跳过、读出一堆垃圾）。
				var cap := _check_capabilities(doc.head)
				if cap != "":
					_flush_fatal(report, cap, notes)
					return null
				block_size = doc.get_block_size()
			QVoxelSpec.BLOCK_MATE:
				doc.materials = _parse_mate(payload, notes)
			QVoxelSpec.BLOCK_VOX0:
				# §5：一个 model_id 恰好对应一个 VOX0 块；重复即为损坏（拒绝整个文件）。
				var model_id: Variant = _parse_vox0_into(doc, payload, block_size, notes)
				if model_id == null:
					return null
				vox0_count += 1
				if entry >= 0:
					doc.block_index[entry]["model_id"] = int(model_id)
			QVoxelSpec.BLOCK_NODE:
				doc.node = _parse_json(payload)
			QVoxelSpec.BLOCK_CACH:
				# §6：只做结构切分（kind / algo_version / source_crc / 余下字节）。
				# 前缀或来源表越界 → 该块损坏，按 §9 的 DROP_BLOCK 跳过，不影响其余块。
				var cach_entry: Variant = _parse_cach(payload)
				if cach_entry == null:
					var msg := "CACH 结构非法（前置或 source_crc 越界），已跳过"
					push_warning("[QVX] " + msg)
					notes.block_dropped(msg)
				else:
					doc.cach.append(cach_entry)
			_:
				# 未知块：按 length 跳过（P1）并**原样留存**以便重写不丢数据。
				# 只有格式层不认识的类型才走这里；CACH 已升为一等块（见 doc.cach）。
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
	var rep := report if report != null else QVoxelReport.new()
	notes.flush_into(rep)
	if validate:
		_validate(doc, rep)
	if report == null:
		for w in rep.warnings:
			push_warning("[QVX] %s" % w)
		for e in rep.errors:
			push_error("[QVX] %s" % e)
	return doc


## 语义校验（§9「语义」一档）：文件级逻辑一致性。
## 在结构层全部通过后调用。doc 会被就地修正（丢弃越界数据）。
static func validate(doc: QVoxelDocument, report: QVoxelReport = null) -> QVoxelReport:
	var rep := report if report != null else QVoxelReport.new()
	if doc == null:
		rep.errors.append("doc 为 null")
		return rep
	_validate(doc, rep)
	if report == null:
		for w in rep.warnings:
			push_warning("[QVX] %s" % w)
		for e in rep.errors:
			push_error("[QVX] %s" % e)
	return rep


static func _validate(doc: QVoxelDocument, rep: QVoxelReport) -> void:
	var B := doc.get_block_size()
	if B <= 0 or (B & (B - 1)) != 0:
		rep.errors.append("HEAD.block_size=%d 不是 2 的幂" % B)
		return
	var n := B * B * B

	# --- channels[0] 必须是 material；通道数必须 == 1（§3.1，本版收敛为单通道） ---
	var channels: Array = doc.get_channels()
	if channels.size() != QVoxelSpec.SUPPORTED_CHANNEL_COUNT:
		rep.errors.append("HEAD.channels 含 %d 个通道，当前版本仅支持 %d 个（%s）" \
				% [channels.size(), QVoxelSpec.SUPPORTED_CHANNEL_COUNT, QVoxelSpec.DOMINANT_CHANNEL])
		return
	var ch0: Variant = channels[0]
	if not (ch0 is Dictionary) or String(ch0.get("name", "")) != QVoxelSpec.DOMINANT_CHANNEL:
		rep.errors.append("HEAD.channels[0].name 必须是 '%s'" % QVoxelSpec.DOMINANT_CHANNEL)
		return
	for ci in channels.size():
		var c: Variant = channels[ci]
		if not (c is Dictionary):
			rep.errors.append("HEAD.channels[%d] 不是对象" % ci)
			return
		if not QVoxelSpec.is_allowed_bpp(int(c.get("bpp", 0))):
			rep.errors.append("HEAD.channels[%d].bpp=%s 不受支持（本版仅 %d 位）" % [ci, c.get("bpp"), QVoxelSpec.CHANNEL_BPP])
			return

	# --- up_axis（§3.1：只允许 x/y/z；其他值按缺省 y 处理并告警，不拒绝文件） ---
	var up := str(doc.head.get("up_axis", QVoxelSpec.DEFAULT_UP_AXIS))
	if not (up in QVoxelSpec.ALLOWED_UP_AXES):
		rep.warnings.append("HEAD.up_axis='%s' 非法（应为 %s），按默认 '%s' 处理" \
				% [up, QVoxelSpec.ALLOWED_UP_AXES, QVoxelSpec.DEFAULT_UP_AXIS])

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

	# --- MATE 条目 0 必须是空气（全零）§4 ---
	# "体素值 == 材质索引"这一无条件等式依赖条目 0 全零；条目 0 非零说明写方材质表错位，
	# 属语义不一致（不致命：索引仍可用，故只告警）。
	var mate_count := doc.materials.size()
	if mate_count > 0 and not _is_air_entry(doc.materials[0]):
		rep.warnings.append("MATE 条目 0 应为全零（空气），实际非零（§4）")

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
			# 【性能】等价于"逐体素 pb[i] < 0 或 pb[i] >= mate_count"，但用原生 min()/max()
			# 两次扫描代替 32768 次 GDScript 循环——这一步曾是加载耗时的绝对主项
			# （实测 196 块 247ms → 约 3ms）。
			var rng := NativeLoader.voxel_value_range(buf as PackedInt32Array)
			if rng.x < 0 or rng.y >= mate_count:
				mate_violations += 1
				bad_keys.append(k)
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


## HEAD 能力门（§3.1 / §10）：读者"必须理解"的东西是否都能理解。
##
## 返回 "" 表示可继续；返回非空字符串表示应拒绝整个文件（FATAL）。
## 【为什么必须在 VOX0 之前】能力不足若只在语义校验阶段报出，VOX0 早已被按错误假设解码，
## 结果是"接受但读错"。门放在最前面，"读不了"就退化成一次明确的拒绝。
static func _check_capabilities(head: Dictionary) -> String:
	# require：读者必须理解的块类型列表；无法处理其中任一者即拒绝（§10）。
	# 不在此列表中的未知块仍按 P1 安全跳过——这正是 glTF extensionsUsed/Required 的分工。
	var req: Variant = head.get("require")
	if req is Array:
		for t in (req as Array):
			var ts := String(t)
			if ts != "" and not QVoxelSpec.can_handle_block_type(ts):
				return "HEAD.require 含本读者无法处理的块类型 '%s'（§10：拒绝整个文件）" % ts
	# channels：当前版本恰好 1 个通道（material）。>1 会让单通道 codec 错读，故拒绝而非静默误读。
	var channels: Variant = head.get("channels")
	if not (channels is Array) or (channels as Array).is_empty():
		return "HEAD.channels 必须是非空数组"
	if (channels as Array).size() != QVoxelSpec.SUPPORTED_CHANNEL_COUNT:
		return "HEAD.channels 含 %d 个通道，当前版本仅支持 %d 个（%s）" \
				% [(channels as Array).size(), QVoxelSpec.SUPPORTED_CHANNEL_COUNT, QVoxelSpec.DOMINANT_CHANNEL]
	return ""


## 记录一次非致命丢弃（block 级）：同时 push 告警并写进报告。
## 只 push 不记账的话，QVoxelReport 会对此完全失明（调用方看不到文件掉了什么）。
static func _push_note(notes: Variant, msg: String) -> void:
	push_warning("[QVX] " + msg)
	if notes is QVoxelNotes:
		(notes as QVoxelNotes).block_dropped(msg)


## 解析 HEAD 的 JSON payload（剥离尾部零填充）。
## 失败原因经 err[0]（1 元素 Array，作为出参）回传，供调用方写入报告。
static func _parse_head(payload: PackedByteArray, err: Array = []) -> Dictionary:
	var reason := ""
	var d := _parse_json(payload)
	if d.is_empty():
		reason = "payload 不是合法 JSON 对象"
	elif not d.has("qvox"):
		reason = "缺少必填键 qvox"
	elif not d.has("channels"):
		reason = "缺少必填键 channels"
	elif int(d["qvox"]) != QVoxelSpec.VERSION:
		reason = "不支持的 qvox 版本 %d（本实现仅支持 %d）" % [int(d["qvox"]), QVoxelSpec.VERSION]
	if reason != "":
		push_error("[QVX] HEAD 不合法：" + reason)
		if not err.is_empty():
			err[0] = reason
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
## 非致命异常（条目数不合法 / 越界）走 _push_note 写进报告，并降级为"无材质"。
static func _parse_mate(payload: PackedByteArray, notes: Variant = null) -> Array:
	var out: Array = []
	if payload.size() < 2:
		_push_note(notes, "MATE payload 不足 2 字节（无法读取 entry_count），按无材质处理")
		return out
	var count := payload.decode_u16(0)
	if count == 0:
		# §4：MATE 里至少含条目 0（空气）。entry_count=0 违反规范 → 视为"未声明材质"并告警。
		_push_note(notes, "MATE entry_count=0（§4 要求至少含条目 0），按无材质处理")
		return out
	var need := 2 + count * QVoxelSpec.MATE_ENTRY_SIZE
	if payload.size() < need:
		_push_note(notes, "MATE 条目越界（声明 %d 条需 %d 字节，实际 %d），按无材质处理"
				% [count, need, payload.size()])
		return out
	for i in count:
		var off := 2 + i * QVoxelSpec.MATE_ENTRY_SIZE
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


## 解析 CACH 负载的**头部**：{ kind, algo_version, source_crc, content_off }。结构非法返回 {}。
##
## content_off = "前置 + 来源表"之后的字节起点（相对负载起点），即 kind 解释者自己的内容起点。
## **不切出内容字节**：供"只建条目索引、不解码缓存"的调用方使用（QVoxelStream 的 CACH 条目
## 索引），免得为每个缓存条目复制一份负载。这是 CACH 头部布局的唯一实现。
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
		"kind": _read_type(payload, 0),
		"algo_version": payload.decode_u16(4),
		"source_crc": source_crc,
		"content_off": need,
	}


## 解析 CACH payload → { kind, algo_version, source_crc, payload }。结构非法返回 null。
##
## 【长度语义】外层块头的 length 含 0–3 字节尾部零填充，而 CACH 的 payload 段本身
## 没有内部长度字段（P2：不存可由他字段推导的值）。因此这里**不剥填充**——
## 原样交出"前置 + 来源表之后的全部字节"，由认识该 kind 的写入方按自己的格式定界。
## 这正是 §6 写明"byte[] payload 余下的全部字节（含块尾填充）"的含义。
static func _parse_cach(payload: PackedByteArray) -> Variant:
	var hdr := parse_cach_header(payload)
	if hdr.is_empty():
		return null
	hdr["payload"] = payload.slice(int(hdr["content_off"]))
	return hdr


## 该 MATE 条目是否为"空气"（§4：条目 0 保留且全零）。
## 判据是**条目语义字段全零**，不直接比 12 字节原始块——因为 reserved 字节按规范写 0，
## 若用原始字节比较，一份 reserved 非零的文件会被误判（而我们只关心可见属性是否为空）。
static func _is_air_entry(entry: Variant) -> bool:
	if not (entry is Dictionary):
		return false
	var e: Dictionary = entry
	for k in ["rgba", "metal", "rough", "hardness", "mass", "e_r", "e_g", "e_b"]:
		if int(e.get(k, 0)) != 0:
			return false
	return true


# ----------------------------------------------------------------------------
# VOX0 子块（17 字节头 + 负载）的**唯一**编解码实现
# ----------------------------------------------------------------------------
# 布局：int32 bx | int32 by | int32 bz | uint8 codec | uint32 payload_length | payload
#
# 【为什么必须收敛到一处】这段布局原先在 4 处各写了一遍（解析 _parse_vox0_into、
# 建子块索引 index_vox0_blocks、整编码 _encode_vox0、增量写 encode_vox0_blocks），
# 偏移量（+4 / +8 / +12 / +13）全是手抄的魔法数。任何一处改动漏改其余三处，就会写出
# 只有自己读得懂、或反之读错的文件；而往返自测可能恰好掩盖这种漂移。
# 因此读写各收敛为一个函数，偏移只在下面出现一次。

## 追加一个 VOX0 子块（17 字节头 + 负载）到 out。
static func write_vox_block(out: PackedByteArray, key: Vector3i, codec: int, payload: PackedByteArray) -> void:
	var off := out.size()
	out.resize(off + QVoxelSpec.VOX_BLOCK_HEADER_SIZE)
	out.encode_u32(off, QVoxelSpec.to_u32(key.x))
	out.encode_u32(off + 4, QVoxelSpec.to_u32(key.y))
	out.encode_u32(off + 8, QVoxelSpec.to_u32(key.z))
	out[off + 12] = codec & 0xFF
	out.encode_u32(off + 13, payload.size())
	out.append_array(payload)


## 从 payload 的 at 处读一个 VOX0 子块头，limit 为该模型负载的精确终点（不含）。
## 头越界或负载越过 limit（截断）→ 返回空字典，调用方据此判 DROP_MODEL。
## 返回 {key, codec, payload_off, payload_len, total}。
static func read_vox_block(payload: PackedByteArray, at: int, limit: int) -> Dictionary:
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


## 解析一个 VOX0 payload 并写入 doc.models。返回 model_id（失败返回 null）。
##
## 模型头 = uint16 model_id + uint32 block_count + uint32 payload_length（共 10 字节）。
## payload_length 精确界定 block[] 的字节数，因此"解析是否正好用完"是一次等式比较，
## **没有任何填充灰区**（见 QVoxelSpec 里 VOX_MODEL_HEADER_SIZE 的说明）。
##
## 失败即拒绝整个文件的情形（FATAL）：头部越界、model_id 重复、codec=0、
##   第一个块不是 HEAD、沿用 HEAD 失败。
## 单个模型不可用（DROP_MODEL）：payload_length 越界、block_count 与负载不自洽。
## 单个块损坏（DROP_BLOCK）：解包失败（含 codec=0、游程数不对、索引越界）。
##   —— 只跳过该块，不牵连模型其余块。
## notes 非 null 时，非致命问题（块丢弃、模型丢弃）写入其中。
static func _parse_vox0_into(doc: QVoxelDocument, payload: PackedByteArray, block_size: int, notes: QVoxelNotes = null) -> Variant:
	if payload.size() < QVoxelSpec.VOX_MODEL_HEADER_SIZE:
		push_error("[QVX] VOX0 头部越界（需要 %d 字节，实得 %d）"
				% [QVoxelSpec.VOX_MODEL_HEADER_SIZE, payload.size()])
		return null
	var model_id := payload.decode_u16(0)
	var block_count := payload.decode_u32(2)
	var payload_length := payload.decode_u32(6)
	# §5：一个 model_id 恰好对应一个 VOX0 块，重复即为损坏（FATAL）。
	if doc.models.has(model_id):
		push_error("[QVX] VOX0 重复的 model_id=%d（每个 model_id 只能有一个块）" % model_id)
		return null

	# --- 长度自洽（精确，无灰区）---
	# 模型负载必须"恰好在 10 + payload_length 处结束"：不能少（截断）、不能多（篡改/残留）。
	# 【档位】payload_length 越界 = DROP_MODEL，不是 FATAL：
	#   顶层块流由块头自己的 length 定界，与其负载声明的 payload_length 无关 —— 该 VOX0
	#   的负载声明再离谱，也不会影响"下一个块头在哪儿"，因此波及范围只到这一个模型。
	#   （§9.0 判据：异常会不会让同一 VOX0 的其余块不可信？会 → DROP_MODEL。）
	var expected_end := QVoxelSpec.VOX_MODEL_HEADER_SIZE + payload_length
	if expected_end > payload.size():
		var msg := "VOX0 model_id=%d 的 payload_length=%d 越界（需要 %d，实得 %d），已丢弃该模型" \
				% [model_id, payload_length, expected_end, payload.size()]
		push_warning("[QVX] " + msg)
		if notes != null:
			notes.model_dropped(msg)
		doc.models[model_id] = {}
		return model_id

	var n := block_size * block_size * block_size
	var blocks: Dictionary = {}
	var pos := QVoxelSpec.VOX_MODEL_HEADER_SIZE
	var truncated := false  # 声明块数多于实际字节
	for _i in block_count:
		var blk := read_vox_block(payload, pos, expected_end)
		if blk.is_empty():
			truncated = true
			break
		var bkey: Vector3i = blk["key"]
		var codec: int = blk["codec"]
		var payload_off: int = blk["payload_off"]
		var plen: int = blk["payload_len"]
		pos = payload_off + plen
		if codec == QVoxelSpec.CODEC_EMPTY:
			# codec=0 是保留值，文件中不应出现（§5.2）→ 该块损坏，跳过（DROP_BLOCK）。
			# 判据：块头里的 plen 已读到，下一个块的位置不受影响，故波及范围只到这一块。
			var msg0 := "VOX0 块 %d,%d,%d 使用了保留 codec=0，已跳过" % [bkey.x, bkey.y, bkey.z]
			push_warning("[QVX] " + msg0)
			if notes != null:
				notes.block_dropped(msg0)
			continue
		var buf := QVoxelBlockCodec.unpack(codec, payload.slice(payload_off, payload_off + plen), n)
		if buf.is_empty():
			# 块损坏 → 跳过该块，保留模型其余块（DROP_BLOCK）
			var msg := "VOX0 块 %d,%d,%d 解包失败，已跳过" % [bkey.x, bkey.y, bkey.z]
			push_warning("[QVX] " + msg)
			if notes != null:
				notes.block_dropped(msg)
			continue
		blocks[bkey] = buf

	# §5 / §9：block_count 与 payload_length 必须自洽 → 否则 DROP_MODEL。
	# 【精确判定】三个条件任一不满足即不一致（无任何灰区）：
	#   1. 声明了块却一个都没解析出来；
	#   2. 解析未完（truncated）；
	#   3. 解析指针未恰好停在 expected_end（多读/少读都是损坏）。
	var mismatch := truncated \
			or (block_count > 0 and pos == QVoxelSpec.VOX_MODEL_HEADER_SIZE) \
			or (pos != expected_end)
	if mismatch:
		var msg := "model_id=%d 的 block_count=%d/payload_length=%d 与负载不自洽（解析到 %d，应为 %d），已丢弃该模型" \
				% [model_id, block_count, payload_length, pos, expected_end]
		push_warning("[QVX] " + msg)
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
# NODE 场景树（§7）
# ----------------------------------------------------------------------------
# 节点是**嵌套**的：顶层 nodes[] 里每一项自己带 children[]（组）或 model_id（模型）。
# 嵌套天然不可能成环（子节点就写在父节点内部），于是不再需要"下标重编号 + 可达性收敛 +
# 三色环检测"那一整套 —— 那些复杂度全部来自"身份即位置"的扁平表示，而扁平表示是 qvx 3 之前的事。
# 校验只剩两件事：非对象项丢弃；kind 不在白名单（group / model）的条目**连同子树**丢弃。
# 任一节点无效时【只丢弃该节点】，不拒绝整个文件（§9）——
# 场景树是易变部分，不该因为一个坏节点毁掉整个模型。

## 从 doc.node 构造已校验的只读视图。丢弃的节点数记入 rep.warnings。
static func _build_scene(doc: QVoxelDocument, rep: QVoxelReport) -> QVoxelSceneGraph:
	var sg := QVoxelSceneGraph.new()
	# 相机**先于 nodes**处理：它不引用任何东西，且"有相机、还没摆模型"是新建工程的常态。
	# 若放在下面 nodes 的提前返回之后，这种文件一存一读就会把 cameras 丢掉。
	sg.cameras = _normalize_object_array(
			doc.node.get(QVoxelSpec.NODE_CAMERAS_KEY), QVoxelSpec.CAMERA_FIELD_DEFAULTS,
			QVoxelSpec.NODE_CAMERAS_KEY, rep,
			{"projection": QVoxelSpec.ALLOWED_CAMERA_PROJECTIONS})
	var raw_nodes: Variant = doc.node.get(QVoxelSpec.NODE_NODES_KEY)
	if not (raw_nodes is Array):
		# 只在"写了 nodes 但不是数组"时告警；键缺失 = 空世界，不是错误。
		if doc.node.has(QVoxelSpec.NODE_NODES_KEY):
			rep.warnings.append("NODE 的 nodes 不是数组，已忽略节点树")
		return sg
	var cleaned := _clean_nodes(raw_nodes as Array)
	sg.nodes = cleaned[0]
	sg.dropped_nodes = int(cleaned[1])
	if sg.dropped_nodes > 0:
		rep.warnings.append("NODE 有 %d 个节点因类型未知/非对象被丢弃（§7）" % sg.dropped_nodes)
	# 动画**原样透传**（§3：本层不解释它）。帧键在扁平表示里是节点下标，而嵌套表示没有下标 ——
	# 于是"校验帧键"在本层无从谈起，交给认识动画语义的调用方（QVoxelAsset）。
	var anims: Variant = doc.node.get("animations")
	if anims is Array:
		sg.animations = anims
	return sg


## 递归清洗嵌套节点树，返回 `[干净数组, 丢弃数]`（含子树内的丢弃）。
##
## 【丢弃规则】① 非 Dictionary 项丢弃；② kind 不在白名单（group / model）的条目丢弃；
## ③ 模型带 children 时只丢 **children**（模型是叶子，组才是唯一容器）——
##    不丢整个节点：children 是冗余键，清掉它这个节点仍然完全可用。
##
## 【为什么 kind 未知要丢整棵子树，而不是"只丢这一层、留下子节点"】kind 未知 = 这一层的语义
## 无法解读，而子节点的坐标 / 合成方式都是**相对它**表达的 —— 留下子节点等于把它们搬进一个
## 不存在的父坐标系里，结果是"内容跑到了错误的位置"。那比直接丢弃更难排查：
## §9 的取向是宁可少给，不可给错。
##
## 【为什么返回两元数组】GDScript 的 int 按值传递，只好用数组把计数带回来。
static func _clean_nodes(arr: Array) -> Array:
	var kept: Array = []
	var dropped := 0
	for item in arr:
		var r := _clean_node(item)
		if not (r[0] as Dictionary).is_empty():
			kept.append(r[0])
		dropped += int(r[1])
	return [kept, dropped]


## 统计一棵（可能非法的）子树里的"节点条目"总数：自身 + 递归所有 children。
## 只在 kind 未知时用：那一支要把整棵子树都算进丢弃数（行为与文档一致）。
static func _count_subtree(item: Variant) -> int:
	if not (item is Dictionary):
		return 1
	var n := 1
	var kids: Variant = (item as Dictionary).get("children")
	if kids is Array:
		for k in (kids as Array):
			n += _count_subtree(k)
	return n


## 清洗单个节点。返回 `[节点字典, 被丢弃的节点数（含本节点与整棵子树）]`；
## 节点字典为 `{}` 表示本节点也被丢弃。
static func _clean_node(item: Variant) -> Array:
	if not (item is Dictionary):
		return [{}, 1]
	var src: Dictionary = item
	var kind := String(src.get("kind", ""))
	if kind != "group" and kind != "model":
		# kind 未知 → 整棵子树一起丢，丢弃数也按整棵子树计（否则诊断数字对不上实际丢掉的内容）
		return [{}, _count_subtree(src)]
	var out: Dictionary = src.duplicate(true)
	if kind == "model":
		out.erase("children")
		return [out, 0]
	var kids: Variant = out.get("children")
	if not (kids is Array):
		# 非数组的 children 按"没有子节点"处理：键清掉，不留半截结构
		out.erase("children")
		return [out, 0]
	var cleaned := _clean_nodes(kids as Array)
	if (cleaned[0] as Array).is_empty():
		out.erase("children")   # 空数组是冗语（P2）
	else:
		out["children"] = cleaned[0]
	return [out, int(cleaned[1])]


## 把 NODE 里的"对象数组"（当前只有 `cameras`）规范成合法项：
## 丢弃非对象项并记警告，按 defaults 补齐**缺失**键，未知键原样保留。
static func _normalize_object_array(raw: Variant, defaults: Dictionary,
		what: String, rep: QVoxelReport, enums := {}) -> Array:
	var out: Array = []
	if raw == null:
		return out
	if not (raw is Array):
		rep.warnings.append("NODE 的 %s 不是数组，已忽略" % what)
		return out
	for item in raw:
		var d: Dictionary = {}
		if item is Dictionary:
			d = (item as Dictionary).duplicate()
		else:
			rep.warnings.append("NODE 的 %s 里有一项不是对象，已丢弃" % what)
			continue
		for k in defaults:
			# 只在**缺失**时补。文件里明写的值（含 false）一律不动 ——
			# 否则 "visible": false 会被缺省值 true 悄悄改回来，且不报错。
			if not d.has(k):
				d[k] = defaults[k]
		# 枚举字段：不在白名单 → 按缺省处理并告警（与 up_axis 同一处置，不拒绝文件）
		for k in enums:
			if d.has(k) and not (d[k] in (enums[k] as Array)):
				rep.warnings.append("NODE 的 %s 有一项 %s=%s 不在白名单，已按缺省处理"
						% [what, k, str(d[k])])
				d[k] = defaults[k]
		out.append(d)
	return out


## 把 JSON 里的整数（int / float / 字符串数字）转成非负整数；非数值/负数返回 -1。
## 注意：Godot 的 JSON 解析把整数也解析为 float，故不能直接用 `is int` 判定。
## 公开：QVoxelWorld 读 `model_id` / `combine` 这类整数字段、QVoxelAsset 解析动画帧的节点键都复用它
## （同一套 JSON 整数语义只该有一份实现）。
static func as_index(v: Variant) -> int:
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


# ----------------------------------------------------------------------------
# 写入
# ----------------------------------------------------------------------------

## 把 QVoxelDocument 序列化为完整 .qvx 字节（含签名）。
static func serialize(doc: QVoxelDocument, include_crc: bool = true) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(QVoxelSpec.signature_bytes())

	# HEAD 必须第一
	_write_block(out, QVoxelSpec.BLOCK_HEAD, _encode_head(doc), include_crc)
	# MATE：只要用到任何非空气材质就写（含条目 0）
	if not doc.materials.is_empty():
		_write_block(out, QVoxelSpec.BLOCK_MATE, _encode_mate(doc), include_crc)
	# VOX0：每个 model 一个块
	for mid in doc.model_ids():
		var blocks: Variant = doc.model_blocks(mid)
		if blocks is Dictionary:
			_write_block(out, QVoxelSpec.BLOCK_VOX0,
					_encode_vox0(mid, blocks as Dictionary, doc.get_block_size()), include_crc)
	# NODE
	if not doc.node.is_empty():
		_write_block(out, QVoxelSpec.BLOCK_NODE, _encode_json(doc.node), include_crc)
	# CACH：派生数据（可删，P5）。写入方提供什么就写什么，格式层不解释 kind。
	append_cach_blocks(out, doc.cach, include_crc)
	# 未知块：原样保留（重写不丢数据）
	for type in doc.unknown_blocks:
		for payload in doc.unknown_blocks[type]:
			_write_block(out, type, payload, include_crc)

	return out


## 把 CACH 条目编码为完整顶层块（含 12 字节块头）并追加到 out。
##
## 供两条路径共用：serialize 全量写、serialize_incremental 追加"变化的条目"
## （旧条目中内容变了的已被跳过，未变的原地搬运）。两条路径都只经过这里，
## 因此 CACH 的字节布局永远只有一处实现（P4 的"块头自足"在写入端的样子）。
static func append_cach_blocks(out: PackedByteArray, entries: Array, include_crc: bool = true) -> void:
	for e in entries:
		if not (e is Dictionary):
			continue
		_write_block(out, QVoxelSpec.BLOCK_CACH, encode_cach(e as Dictionary), include_crc)


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
	out.append_array(entry.get("payload", PackedByteArray()))
	return out


## 【增量写盘】在旧文件字节的基础上重写，未变的块直接搬运原始字节，只重编码脏块。
##
## 前提：old_doc.block_index 有效（由 parse_with_index(old_bytes) 得到）。
##   **不再要求"块集合未变"**：VOX0 的增删块由 encode_vox0_blocks 就地处理（新增的按坐标序
##   追加、删除的跳过、整个 model 空了就不写该块），故调用方无需预判"能否走增量"。
##
## 【关键契约】new_doc.models 装的是**脏块内容覆盖层，不是全世界**（model_id →
##   { chunk_key: PackedInt32Array }）。存储层已不再常驻全世界的解码镜像（那是内存无界
##   增长的根源），因此这里拿不到"完整模型"，只有"变了的那几块的内容"。未变子块的字节
##   由旧索引定位、从 old_bytes 原样搬运——这也是子块级增量的全部收益来源。
##
## 参数：
##   old_bytes      旧文件完整字节（含签名）
##   old_doc        对 old_bytes 调 parse_with_index 得到的文档（其 block_index 提供块区间）
##   new_doc        修改后的文档。models 为脏块覆盖层（见上），其余字段为最终值。
##   dirty_models   { model_id: true }——需要重建 VOX0 的 model；其余 model 原样搬运。
##   dirty_global   是否重编码 HEAD/MATE/NODE（materials、metadata、node 变动时置 true）
##   deleted_chunks { model_id: { chunk_key(Vector3i): true } }——被**删除**的块。
##                  与 new_doc.models 里的写入键合起来即"全部变更键"：写入的重编码、
##                  删除的跳过、其余子块搬运旧字节（实测 144 块改 1 块：2000ms → ~15ms）。
##   vox0_index     【二级索引缓存，可选】{ model_id(int): index_vox0_blocks() 的结果 }。
##                  index_vox0_blocks 要对整个 VOX0 负载算一遍子块 CRC（1.4MB ≈ 90ms），
##                  若每次写盘都重算，子块级增量的收益会被它吃光。由调用方（QVoxelStream）
##                  在加载时建一次、写盘后增量维护，后续写盘直接复用 → 归零。
##                  缺省/未命中 → 现场重算索引（正确但慢），保证旧调用方不受影响。
##   dirty_cach_blocks
##                 需要**替换/删除**的旧 CACH 顶层块偏移集合 { block_offset(int): true }。
##                 在集合里的旧块被跳过（不搬运），新条目由 new_doc.cach 在末尾追加；
##                 不在集合里的旧 CACH 原样搬运（缓存内容与其来源都没变）。
##                 【为什么按块偏移而不是整体布尔】派生缓存由调用方（QVoxelStream）**按条目**
##                 持有：它只留"变化的那几条"在内存里，其余条目仍躺在磁盘上。整体 bool 会
##                 迫使调用方交出完整缓存（又回到常驻镜像），逐条 diff 又要格式层解释 kind；
##                 而"哪些旧块要换掉"是调用方（索引持有者）已经知道的事实，直接给偏移最省。
##                 空集合 = 没有条目要替换，此时 new_doc.cach 也应为空。
##   返回值：新文件字节。确定性：同一输入必得同一输出。
static func serialize_incremental(old_bytes: PackedByteArray, old_doc: QVoxelDocument, new_doc: QVoxelDocument, dirty_models: Dictionary, dirty_global: bool, include_crc: bool = true, deleted_chunks: Dictionary = {}, vox0_index: Dictionary = {}, dirty_cach_blocks: Dictionary = {}) -> PackedByteArray:
	# 无旧索引就无从搬运旧块。此时调用方须保证 new_doc 自带完整世界（首写场景），退回全量写。
	if old_doc == null or old_doc.block_index.is_empty():
		return serialize(new_doc, include_crc)

	var out := PackedByteArray()
	out.append_array(QVoxelSpec.signature_bytes())
	var block_size := new_doc.get_block_size()

	# 按旧文件的物理块顺序重建：HEAD 必须第一个（规范 §1 / §3）。
	# 先写 HEAD，再写其余块（跳过在 out 中已写的 HEAD）。
	for idx in old_doc.block_index.size():
		var bi: Dictionary = old_doc.block_index[idx]
		var type: String = bi["type"]
		if type == QVoxelSpec.BLOCK_HEAD:
			# HEAD：dirty_global 或 head 变化 → 重编码；否则搬运
			if dirty_global or _head_changed(old_doc, new_doc):
				_write_block(out, QVoxelSpec.BLOCK_HEAD, _encode_head(new_doc), include_crc)
			else:
				_copy_block(old_bytes, out, bi)
			continue
		if type == QVoxelSpec.BLOCK_MATE:
			if dirty_global or _mate_changed(old_doc, new_doc):
				if not new_doc.materials.is_empty():
					_write_block(out, QVoxelSpec.BLOCK_MATE, _encode_mate(new_doc), include_crc)
				# materials 变空 → 丢弃 MATE 块（不写）
			else:
				_copy_block(old_bytes, out, bi)
			continue
		if type == QVoxelSpec.BLOCK_VOX0:
			var mid: int = int(bi.get("model_id", -1))
			if mid >= 0 and dirty_models.has(mid):
				var overlay := _as_blocks(new_doc.model_blocks(mid))
				var deleted := _as_deleted(deleted_chunks.get(mid))
				# 【子块级增量】只重编码脏块：未变子块搬运旧字节，块集合的增删就地处理。
				# vox0_index 命中则免去子块重索引（对 1.4MB 负载约省 90ms）。
				var old_payload := _block_payload(old_bytes, bi)
				var old_index: Variant = vox0_index.get(mid)
				if not (old_index is Dictionary) or (old_index as Dictionary).is_empty():
					old_index = index_vox0_blocks(old_payload, block_size)
				var payload_vox0 := encode_vox0_blocks(old_payload, old_index, overlay, deleted, block_size)
				if payload_vox0.is_empty():
					continue   # 该 model 已无任何块 → 不写（等同删除整个 VOX0）
				payload_vox0.encode_u16(0, mid & 0xFFFF)   # 回填 model_id
				_write_block(out, QVoxelSpec.BLOCK_VOX0, payload_vox0, include_crc)
			else:
				_copy_block(old_bytes, out, bi)
			continue
		if type == QVoxelSpec.BLOCK_NODE:
			if dirty_global or _node_changed(old_doc, new_doc):
				if not new_doc.node.is_empty():
					_write_block(out, QVoxelSpec.BLOCK_NODE, _encode_json(new_doc.node), include_crc)
			else:
				_copy_block(old_bytes, out, bi)
			continue
		if type == QVoxelSpec.BLOCK_CACH:
			# 只有"内容变了的"旧块被跳过（其偏移由调用方给出），未变的原样搬运
			# （缓存内容与其来源都没变）；新条目在末尾统一追加。
			# 【为什么不整体重写】派生缓存由调用方**按条目**持有：未变的条目仍躺在磁盘上，
			# 无须（也无法）在内存里重建 —— 整批重写会把它们丢掉。
			if not dirty_cach_blocks.has(int(bi["offset"])):
				_copy_block(old_bytes, out, bi)
			continue
		# 未知块：原样搬运（重写不丢数据）
		_copy_block(old_bytes, out, bi)

	# 兜底：新 doc 里存在但旧文件没有的 model（旧文件里没有它的 VOX0 块可搬运）。
	# 此时覆盖层即该 model 的完整内容（它从未落过盘），直接整编码追加，保证不丢数据。
	var old_model_ids := {}
	for idx in old_doc.block_index.size():
		var bi: Dictionary = old_doc.block_index[idx]
		if bi["type"] == QVoxelSpec.BLOCK_VOX0:
			old_model_ids[int(bi.get("model_id", -1))] = true
	for mid in new_doc.model_ids():
		if old_model_ids.has(mid):
			continue
		var blocks: Variant = new_doc.model_blocks(mid)
		if not (blocks is Dictionary) or _model_is_empty(blocks as Dictionary):
			continue
		_write_block(out, QVoxelSpec.BLOCK_VOX0, _encode_vox0(mid, blocks, block_size), include_crc)

	# CACH：新条目（内容变化 / 新增的）统一追加在末尾；变了的旧块已在上面被跳过。
	# CACH 允许出现在文件任意位置（§2 表），故"跳过旧块 + 末尾追加"天然等价于一次按条目替换。
	append_cach_blocks(out, new_doc.cach, include_crc)

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
## 额外返回特殊键 "_meta"：
##   { "order": [Vector3i…],           // 子块的物理顺序（增量写据此保持字节序）
##     "sub": { key: {"crc": int} } }  // 每个子块的 CRC32
## 子块 CRC 同时是 LOD 派生缓存（CACH）的来源校验依据：缓存的 source_crc 就是它所依赖的
## LOD0 子块 CRC 集合（见 _lod_expected_crcs）。
##
## 注意：这里的 offset 全部**相对 payload 起点**，而函数看不到文件位置，故"该 payload 在文件
## 中的绝对偏移"由调用方补进 `_meta.base`（按块随机读盘时要把两者相加）。
static func index_vox0_blocks(payload: PackedByteArray, _block_size: int) -> Dictionary:
	var out: Dictionary = {}
	if payload.size() < QVoxelSpec.VOX_MODEL_HEADER_SIZE:
		return out
	var block_count := payload.decode_u32(2)
	var payload_length := payload.decode_u32(6)
	# 精确终点：与 _parse_vox0_into 同一套判据（模型负载恰好在此结束）
	var expected_end := mini(QVoxelSpec.VOX_MODEL_HEADER_SIZE + payload_length, payload.size())
	var pos := QVoxelSpec.VOX_MODEL_HEADER_SIZE
	var order: Array = []
	var subs: Dictionary = {}
	for _i in block_count:
		var blk := read_vox_block(payload, pos, expected_end)
		if blk.is_empty():
			break
		if int(blk["codec"]) == QVoxelSpec.CODEC_EMPTY:
			break
		var head_off := pos
		var key: Vector3i = blk["key"]
		var block_total: int = blk["total"]
		out[key] = {
			"head_off": head_off,
			"codec": blk["codec"],
			"payload_off": blk["payload_off"],
			"payload_len": blk["payload_len"],
			"block_total": block_total,
		}
		order.append(key)
		# 记录子块（含 17 字节头）的 CRC：增量写与 LOD 缓存来源校验共用
		subs[key] = {"crc": _slice_crc(payload, head_off, block_total)}
		pos = int(blk["payload_off"]) + int(blk["payload_len"])
	out["_meta"] = {"order": order, "sub": subs}
	return out


## CRC32（标准 IEEE 802.3，反射多项式 0xEDB88320）——统一由原生 VoxelNative 计算。
##
## 读写两端共用这一处实现：读取端校验块 CRC，写入端算块 CRC，增量写算子块 CRC。
## 原生下 1.4MB 约 0.5ms；GDScript 逐字节查表要 ~84ms，且 crc32_combine 拼接在解释器下
## 比整扫更慢（实测 1.48ms/次），因此不保留兜底——原生库为硬依赖（见 NativeLoader）。
static func _slice_crc(data: PackedByteArray, start: int, length: int) -> int:
	return NativeLoader.crc32(data, start, length)


## 一个块的 CRC：覆盖 length(4) ‖ type(4) ‖ 负载的 length 字节（含尾部零填充）。
## 两段不连续（中间隔着 crc 字段），交给 crc32_segments 一次算完，免去临时拼接。
static func _block_crc(full: PackedByteArray, header_at: int, length: int) -> int:
	return NativeLoader.crc32_segments(full,
			PackedInt64Array([header_at, header_at + QVoxelSpec.BLOCK_HEADER_SIZE]),
			PackedInt64Array([8, length]))


## 【子块级增量编码】由一个 model 的旧负载索引 + **变更内容覆盖层** + 删除集重建 VOX0 负载。
##
## 与旧实现的根本差别：旧版要求传入"完整的新块字典"（全世界都得在内存里），本版只传**变了
## 的那几块**——因为存储层已不再常驻全世界的解码镜像。未变子块在旧、新负载里偏移完全相同，
## 故把**连续的未变段**合并成一次 old_payload.slice + append_array（原生 memcpy，
## 1.7MB 约 1.5ms）；脏块通常只有一两个 → 大段拷贝从 144 次降到 2~4 次。
##
## 块集合的增删也就地处理，因此不再有"不适用增量就退回整编码"的失败分支：
##   未变（既不在 overlay 也不在 deleted）→ 搬运旧字节
##   写入（在 overlay 里）→ 重新挑 codec 并编码；若编码为空块则丢弃（空块不落盘，P2）
##   删除（在 deleted 里且不在 overlay）→ 跳过
##   新增（在 overlay 里但旧索引没有）→ 按坐标排序追加在末尾（保证同一输入同一输出）
##
## 返回不含 model_id 的负载（前 2 字节占位 0，由调用方回填）；最终一块都不剩时返回空。
## CRC 由写入方统一算（_block_crc），此处不重复。
static func encode_vox0_blocks(old_payload: PackedByteArray, old_index: Dictionary, overlay: Dictionary, deleted: Dictionary, block_size: int) -> PackedByteArray:
	var n := block_size * block_size * block_size
	var body := PackedByteArray()
	var count := 0

	# 1) 旧物理顺序：未变搬运 / 变更重编码 / 删除跳过
	var order: Array = (old_index.get("_meta", {}) as Dictionary).get("order", [])
	for k in order:
		if overlay.has(k):
			if _append_encoded_block(body, k, overlay[k], n):
				count += 1
			continue
		if deleted.has(k):
			continue
		var info: Dictionary = old_index[k]
		body.append_array(old_payload.slice(int(info["head_off"]),
				int(info["head_off"]) + int(info["block_total"])))
		count += 1

	# 2) 旧索引里没有的新增键：按坐标排序追加（物理顺序旧的在前、新的在后，确定性不依赖遍历顺序）
	var appended: Array = []
	for k in overlay:
		if not old_index.has(k):
			appended.append(k)
	appended.sort_custom(func(a, b):
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	for k in appended:
		if _append_encoded_block(body, k, overlay[k], n):
			count += 1

	if count == 0:
		return PackedByteArray()

	# 【10 字节模型头】model_id(2) + block_count(4) + payload_length(4)。
	# payload_length 是 VOX0 内部贯彻 P4 的关键：子块逐个自足还不够，**整段负载也要自足**，
	# 否则解析器无法判断"负载到此为止"还是"后面还有填充"（见 QVoxelSpec.VOX_MODEL_HEADER_SIZE）。
	var out := PackedByteArray()
	out.resize(QVoxelSpec.VOX_MODEL_HEADER_SIZE)
	out.encode_u16(0, 0)  # model_id 占位，调用方写
	out.encode_u32(2, count)
	out.encode_u32(6, body.size())
	out.append_array(body)
	return out


## 编码一个子块并追加到 body（空块/尺寸不对 → 不写，返回 false）。
static func _append_encoded_block(body: PackedByteArray, key: Vector3i, buf: PackedInt32Array, n: int) -> bool:
	if buf.size() != n:
		return false
	var picked := QVoxelBlockCodec.choose_and_pack(buf, n)
	var codec: int = picked.get("codec", QVoxelSpec.CODEC_EMPTY)
	if codec == QVoxelSpec.CODEC_EMPTY:
		return false   # 全空 → 该块不落盘（P2）
	write_vox_block(body, key, codec, picked.get("payload", PackedByteArray()))
	return true


## 取一个顶层块的负载字节（跳过 12 字节块头）。区间越界返回空。
static func _block_payload(bytes: PackedByteArray, bi: Dictionary) -> PackedByteArray:
	var off: int = int(bi["offset"])
	var end := off + int(bi["total"])
	if end > bytes.size():
		return PackedByteArray()
	return bytes.slice(off + QVoxelSpec.BLOCK_HEADER_SIZE, end)


## 把 new_doc.model_blocks() 的结果安全收窄为"覆盖层字典"（非字典 → 空）。
static func _as_blocks(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


## 把 deleted_chunks[mid] 安全收窄为删除集（非字典 → 空）。
static func _as_deleted(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


static func _copy_block(old_bytes: PackedByteArray, out: PackedByteArray, bi: Dictionary) -> void:
	var off: int = bi["offset"]
	var total: int = bi["total"]
	out.append_array(old_bytes.slice(off, off + total))


static func _head_changed(a: QVoxelDocument, b: QVoxelDocument) -> bool:
	return JSON.stringify(a.head) != JSON.stringify(b.head)


static func _mate_changed(a: QVoxelDocument, b: QVoxelDocument) -> bool:
	return a.materials.size() != b.materials.size() or JSON.stringify(a.materials) != JSON.stringify(b.materials)


static func _node_changed(a: QVoxelDocument, b: QVoxelDocument) -> bool:
	return JSON.stringify(a.node) != JSON.stringify(b.node)


## model 是否"空"（没有任何非空块）。空 model 不写 VOX0。
## 判空用原生 `count(0)`（与 QVoxelStream._prune_empty 同因：逐体素 GDScript 扫描在
## 写盘时是秒级开销，原生是毫秒级）。
static func _model_is_empty(blocks: Dictionary) -> bool:
	for k in blocks:
		var buf: PackedInt32Array = blocks[k]
		if buf.count(0) != buf.size():
			return false
	return true


## 写一个块：length（含填充）+ type + crc32 + payload + 零填充。
static func _write_block(out: PackedByteArray, type: String, payload: PackedByteArray, include_crc: bool) -> void:
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
	# 零填充到 length
	for _p in (length - payload.size()):
		out.append(0)
	# CRC 覆盖 length ‖ type ‖ 负载的 length 个字节（含尾部填充）。
	# 此刻 out 已含 [header(12) + payload + padding]，直接对这段连续字节算 CRC。
	if include_crc:
		var crc := _block_crc(out, header_at, length)
		out.encode_u32(header_at + 8, crc)
	else:
		out.encode_u32(header_at + 8, 0)


## HEAD JSON 编码：紧凑序列化（无多余空白）+ UTF-8 字节。
static func _encode_head(doc: QVoxelDocument) -> PackedByteArray:
	# §3.1：qvx 必须是**第一个键**（让读者一眼判断兼容性），而 JSON 的键序
	# 由字典插入顺序决定 —— 直接 stringify(doc.head) 只在调用方恰好先塞 qvx 时成立，
	# 任何直接构造 head 的调用方都可能破坏它。这里显式重排，把规则落到编码器里，
	# 而不是依赖每处调用方的自觉。
	var ordered := _head_with_qvox_first(doc.head)
	return _encode_json(ordered)


## 返回一个 head 的副本，保证 "qvox" 位于第一个键（若原 head 无 qvx 则原样返回）。
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
## 排序后 qvx 永远排后面）。传 false 才能保留字典插入顺序。
static func _encode_json(d: Dictionary) -> PackedByteArray:
	var text := JSON.stringify(d, "", false)  # 无缩进 + 保留插入顺序
	return text.to_utf8_buffer()


## MATE 编码：uint16 count + count×12 字节。
static func _encode_mate(doc: QVoxelDocument) -> PackedByteArray:
	var count := doc.materials.size()
	var out := PackedByteArray()
	out.resize(2 + count * QVoxelSpec.MATE_ENTRY_SIZE)
	out.encode_u16(0, count & 0xFFFF)
	for i in count:
		var m: Dictionary = doc.materials[i]
		var off := 2 + i * QVoxelSpec.MATE_ENTRY_SIZE
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
## 使读取端无需再靠"剩余 < 4 字节"这种模糊判定来容忍顶层填充（见 QVoxelSpec 的说明）。
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
		var picked := QVoxelBlockCodec.choose_and_pack(buf, n)
		var codec: int = picked.get("codec", QVoxelSpec.CODEC_EMPTY)
		if codec == QVoxelSpec.CODEC_EMPTY:
			continue  # 空块不写入
		packed_blocks.append([k, codec, picked.get("payload", PackedByteArray())])

	# 先把块数组写进一个临时缓冲，得到精确的 payload_length
	var body := PackedByteArray()
	for item in packed_blocks:
		write_vox_block(body, item[0], item[1], item[2])

	var out := PackedByteArray()
	out.resize(QVoxelSpec.VOX_MODEL_HEADER_SIZE)
	out.encode_u16(0, model_id & 0xFFFF)
	out.encode_u32(2, packed_blocks.size())
	out.encode_u32(6, body.size())  # payload_length：精确的 block[] 字节数
	out.append_array(body)
	return out
