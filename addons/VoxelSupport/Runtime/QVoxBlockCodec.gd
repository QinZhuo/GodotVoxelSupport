@tool
class_name QVoxBlockCodec
extends RefCounted

## QVox 块级编解码器。
##
## 输入 / 输出统一为 PackedInt32Array（长度为块内体素数 N = B³，值 = 材质ID，0 = 空）。
## 这里只处理【单通道 material】——v1 的 VOX0 在无附加通道时是主流情形，也是
## INDEXED 唯一支持的编解码（附加通道不支持 INDEXED，改用 DENSE/RUN）。
##
## 块内遍历顺序恒为 ZXY 线性下标：idx = x + y·B + z·B²（X 最快）。
## 本类的 pack/unpack 全部按该顺序，与 QVoxSpec 的约定一致。
##
## 编解码一览：
##   EMPTY   0  保留值，永不写入文件（空块 = 块坐标缺失）
##   SOLID   1  负载 = 一个值（单通道时 2 字节）
##   RUN     2  uint32 count + count×(varint 游程长度, 值)
##   DENSE   3  N × bpp/8 字节，ZXY 顺序
##   INDEXED 4  uint8 n + n 个材质索引 + N×⌈log₂n⌉ 位

const U8_MAX := 255


# ----------------------------------------------------------------------------
# 编解码选择
# ----------------------------------------------------------------------------

## 为一个块缓冲挑选体积最小的编解码，返回 [codec, payload_bytes]。
## EMPTY 返回 [CODEC_EMPTY, 0]（调用方据此跳过——空块不写入文件）。
## 只在 SOLID / RUN / DENSE / INDEXED 之间比较（INDEXED 仅在可用时参与）。
##
## 【性能】GDScript 逐元素循环很贵（32³ = 32768 次；实测一次裸循环 0.53~0.85ms）。
## 策略是**按代价递增、尽早退出**，绝不为每个候选各扫一遍：
##   1. 第 1 趟：EMPTY / SOLID（命中率最高，命中即刻返回，零后续代价）。
##   2. 第 2 趟：一趟同时算 RUN 的精确字节数 + 取值上界（用于判断 INDEXED 是否值得算）。
##   3. INDEXED 只有当"取值数很少（≤255）且理论上可能更小"时才真正构造计算。
## DENSE 的字节数是纯算术，不占循环。
static func pick_codec(buf: PackedInt32Array, n: int) -> Array:
	if n <= 0:
		return [QVoxSpec.CODEC_EMPTY, 0]

	# ---- 第 1 趟：EMPTY / SOLID 快速判定（尽早退出，命中率最高）----
	# 用 `_all_equal`（n == 整块时底层是原生 count）判"全零 / 全同"：这两种是写入时最常见的
	# 形态，而 GDScript 的 `for i in n` 判定在"全同"时**不会 break**，要走满 n 次
	# （实测 32768 次约 1.1ms/块）；原生 count 约 25µs/次，对 EMPTY/SOLID 块是 ~40 倍。
	# 代价：混合块会白付一次原生 count，相对其后续两趟扫描可忽略。
	var first: int = buf[0]
	if _all_equal(buf, n, 0):
		return [QVoxSpec.CODEC_EMPTY, 0]
	if first != 0 and _all_equal(buf, n, first):
		return [QVoxSpec.CODEC_SOLID, QVoxSpec.CHANNEL_BYTES]  # 单通道 bpp=16 → 2 字节

	# ---- 第 2 趟：RUN 精确字节 + 取值跨度（min/max）----
	# 跨度 (max-min) ≤ 255 是"取值数 ≤ 256"的必要条件，用做 INDEXED 的廉价预筛。
	var run_bytes := 4                  # uint32 count
	var run_len := 1
	var run_val: int = first
	var vmax: int = first
	var vmin: int = first
	for i in range(1, n):
		var v: int = buf[i]
		if v == run_val:
			run_len += 1
		else:
			run_bytes += _varint_size(run_len) + QVoxSpec.CHANNEL_BYTES   # varint 长度 + 通道值
			run_val = v
			run_len = 1
		if v > vmax:
			vmax = v
		elif v < vmin:
			vmin = v
	run_bytes += _varint_size(run_len) + QVoxSpec.CHANNEL_BYTES

	var dense_bytes := n * QVoxSpec.CHANNEL_BYTES   # bpp=16
	var best_codec := QVoxSpec.CODEC_DENSE
	var best_bytes := dense_bytes
	if run_bytes < best_bytes:
		best_codec = QVoxSpec.CODEC_RUN
		best_bytes = run_bytes

	# ---- INDEXED：仅在"取值跨度 ≤ 255"时才真正统计（否则必然不可用）----
	# 建字典这一步最贵，尽量少做：跨度预筛能拦掉绝大多数高熵块。
	if vmax - vmin <= U8_MAX:
		var distinct := {first: true}
		var distinct_ok := true
		for i in range(1, n):
			distinct[buf[i]] = true
			if distinct.size() > U8_MAX:
				distinct_ok = false
				break
		if distinct_ok:
			var bits := _bits_for(distinct.size())
			var indexed_bytes := 1 + distinct.size() * QVoxSpec.CHANNEL_BYTES + ((n * bits + 7) >> 3)
			if indexed_bytes < best_bytes:
				best_codec = QVoxSpec.CODEC_INDEXED
				best_bytes = indexed_bytes

	return [best_codec, best_bytes]


## 前 n 个元素是否全等于 v。
## n == buf.size()（正常情形）走原生 count；n 小于缓冲长度时退回逐元素（罕见路径，
## 此前的逐元素写法在这里是唯一实现，抽出来顺带把"整块"路径提速）。
static func _all_equal(buf: PackedInt32Array, n: int, v: int) -> bool:
	if n != buf.size():
		for i in n:
			if buf[i] != v:
				return false
		return true
	return buf.count(v) == n


## 精确计算 RUN 编码的负载字节数（不实际构造，只累加长度）。
## 保留为独立函数供外部/测试调用；pick_codec 内部已融合进单趟扫描，不调用它。
static func _estimate_run_bytes(buf: PackedInt32Array, n: int) -> int:
	if n <= 0:
		return 4
	var total := 4
	var i := 0
	while i < n:
		var v := buf[i]
		var run := 1
		while i + run < n and buf[i + run] == v:
			run += 1
		total += _varint_size(run) + QVoxSpec.CHANNEL_BYTES  # 长度 varint + 通道值
		i += run
	return total


## LEB128 编码 value 所需的字节数。
static func _varint_size(value: int) -> int:
	var v := value
	var size := 1
	while v >= 0x80:
		v >>= 7
		size += 1
	return size


## 表示 value 需要的最少位数（value ≥ 1；value=1 用 1 位）。
static func _bits_for(value: int) -> int:
	var bits := 0
	var v := value - 1
	while v > 0:
		bits += 1
		v >>= 1
	return maxi(bits, 1)


# ----------------------------------------------------------------------------
# 打包
# ----------------------------------------------------------------------------

## 按 codec 打包块缓冲，返回负载字节（PackedByteArray）。
static func pack(codec: int, buf: PackedInt32Array, n: int) -> PackedByteArray:
	match codec:
		QVoxSpec.CODEC_SOLID:
			return _pack_solid(buf)
		QVoxSpec.CODEC_RUN:
			return _pack_run(buf, n)
		QVoxSpec.CODEC_DENSE:
			return _pack_dense(buf, n)
		QVoxSpec.CODEC_INDEXED:
			return _pack_indexed(buf, n)
	return PackedByteArray()


## SOLID：单通道一个 uint16 值。
static func _pack_solid(buf: PackedInt32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(QVoxSpec.CHANNEL_BYTES)
	var v: int = buf[0] if buf.size() > 0 else 0
	out.encode_u16(0, v & 0xFFFF)
	return out


## RUN：uint32 count + count×(varint 游程长度, uint16 值)。
static func _pack_run(buf: PackedInt32Array, n: int) -> PackedByteArray:
	var out := PackedByteArray()
	var lens := PackedInt32Array()
	var vals := PackedInt32Array()
	var i := 0
	while i < n:
		var v := buf[i]
		var run := 1
		while i + run < n and buf[i + run] == v:
			run += 1
		lens.append(run)
		vals.append(v)
		i += run
	# 头部 count（4 字节）
	out.resize(4)
	out.encode_u32(0, lens.size())
	# 每段：varint 长度 + uint16 值
	for k in lens.size():
		_append_varint(out, lens[k])
		var off := out.size()
		out.resize(off + QVoxSpec.CHANNEL_BYTES)
		out.encode_u16(off, vals[k] & 0xFFFF)
	return out


## DENSE：N × uint16，ZXY 顺序。
##
## 【性能】逐元素 `encode_u16` 在 32³ = 32768 次时约 4ms。这里改走原生路径：
## `PackedInt32Array.to_byte_array()` 是引擎 C++ 侧的内存直拷（131072 字节仅 0.01ms），
## 但它是 4 字节/元素，需要再把 int32 的高 2 字节丢弃、低 2 字节按序取出来。
## 既然内存布局本就是小端 IE，等价于「每 4 字节取前 2 字节」——用 `slice` 步进做不到，
## 但可以一次性 `to_byte_array()` 后按 4 步长拼接，比逐元素 encode 快得多。
static func _pack_dense(buf: PackedInt32Array, n: int) -> PackedByteArray:
	# int32 → 字节（原生直拷）→ 每 4 字节取低 2 字节
	var raw := buf.to_byte_array()
	var out := PackedByteArray()
	out.resize(n * QVoxSpec.CHANNEL_BYTES)
	var dst := 0
	for i in n:
		var src := i * 4   # int32 元素步长（4 字节），与通道宽度无关
		out[dst] = raw[src]
		out[dst + 1] = raw[src + 1]
		dst += QVoxSpec.CHANNEL_BYTES
	return out


## INDEXED：uint8 n + n 个 uint16 材质值 + 每体素 ⌈log₂n⌉ 位的索引。
static func _pack_indexed(buf: PackedInt32Array, n: int) -> PackedByteArray:
	# 建立值表（保持首次出现顺序，确定即可）
	var table := PackedInt32Array()
	var index_of := {}
	for i in n:
		var v := buf[i]
		if not index_of.has(v):
			index_of[v] = table.size()
			table.append(v)
	var bits := _bits_for(table.size())
	var out := PackedByteArray()
	out.resize(1)
	out[0] = table.size() & 0xFF
	# 值表
	var off := out.size()
	out.resize(off + table.size() * QVoxSpec.CHANNEL_BYTES)
	for k in table.size():
		out.encode_u16(off + k * QVoxSpec.CHANNEL_BYTES, table[k] & 0xFFFF)
	# 位打包索引
	var bit_buf := PackedByteArray()
	var total_bits := n * bits
	bit_buf.resize((total_bits + 7) >> 3)
	var bit_pos := 0
	for i in n:
		var code: int = index_of[buf[i]]
		for b in bits:
			if (code >> b) & 1:
				var byte_i := bit_pos >> 3
				bit_buf[byte_i] = bit_buf[byte_i] | (1 << (bit_pos & 7))
			bit_pos += 1
	out.append_array(bit_buf)
	return out


# ----------------------------------------------------------------------------
# 解包
# ----------------------------------------------------------------------------

## 按 codec 解包负载，返回长度 n 的缓冲。失败（负载损坏）返回空数组。
static func unpack(codec: int, payload: PackedByteArray, n: int) -> PackedInt32Array:
	match codec:
		QVoxSpec.CODEC_SOLID:
			return _unpack_solid(payload, n)
		QVoxSpec.CODEC_RUN:
			return _unpack_run(payload, n)
		QVoxSpec.CODEC_DENSE:
			return _unpack_dense(payload, n)
		QVoxSpec.CODEC_INDEXED:
			return _unpack_indexed(payload, n)
	return PackedInt32Array()


static func _unpack_solid(payload: PackedByteArray, n: int) -> PackedInt32Array:
	if payload.size() < QVoxSpec.CHANNEL_BYTES:
		return PackedInt32Array()
	var v := payload.decode_u16(0)
	var buf := PackedInt32Array()
	buf.resize(n)
	for i in n:
		buf[i] = v
	return buf


static func _unpack_run(payload: PackedByteArray, n: int) -> PackedInt32Array:
	if payload.size() < 4:
		return PackedInt32Array()
	var count := payload.decode_u32(0)
	var buf := PackedInt32Array()
	buf.resize(n)
	var pos := 4
	var idx := 0
	for _k in count:
		var r := _read_varint(payload, pos)
		if r[0] < 0:
			return PackedInt32Array()  # varint 越界 → 损坏
		var run_len: int = r[0]
		pos = r[1]
		if pos + QVoxSpec.CHANNEL_BYTES > payload.size():
			return PackedInt32Array()
		var v := payload.decode_u16(pos)
		pos += QVoxSpec.CHANNEL_BYTES
		for _j in run_len:
			if idx >= n:
				return PackedInt32Array()  # 游程和超过 N → 损坏
			buf[idx] = v
			idx += 1
	if idx != n:
		return PackedInt32Array()  # 游程和 ≠ N → 损坏（§9 不变量）
	return buf


static func _unpack_dense(payload: PackedByteArray, n: int) -> PackedInt32Array:
	if payload.size() < n * QVoxSpec.CHANNEL_BYTES:
		return PackedInt32Array()
	# 先把 uint16 序列还原为 int32 字节布局（每元素低 2 字节 + 2 个 0），
	# 再交给原生 `to_int32_array()` 直拷。比逐元素 `decode_u16` 快得多。
	var wide := PackedByteArray()
	wide.resize(n * 4)   # int32 元素步长（4 字节）
	var src := 0
	var dst := 0
	for i in n:
		wide[dst] = payload[src]
		wide[dst + 1] = payload[src + 1]
		src += QVoxSpec.CHANNEL_BYTES
		dst += 4
	return wide.to_int32_array()


static func _unpack_indexed(payload: PackedByteArray, n: int) -> PackedInt32Array:
	if payload.size() < 1:
		return PackedInt32Array()
	var count := payload[0]
	if count == 0:
		# n=0 → 全空
		var empty := PackedInt32Array()
		empty.resize(n)
		return empty
	var table_end := 1 + count * QVoxSpec.CHANNEL_BYTES
	if payload.size() < table_end:
		return PackedInt32Array()
	var table := PackedInt32Array()
	table.resize(count)
	for k in count:
		table[k] = payload.decode_u16(1 + k * QVoxSpec.CHANNEL_BYTES)
	var bits := _bits_for(count)
	var needed := (n * bits + 7) >> 3
	if payload.size() < table_end + needed:
		return PackedInt32Array()
	var buf := PackedInt32Array()
	buf.resize(n)
	var bit_pos := 0
	for i in n:
		var code := 0
		for b in bits:
			var byte_i := table_end + (bit_pos >> 3)
			if (payload[byte_i] >> (bit_pos & 7)) & 1:
				code |= (1 << b)
			bit_pos += 1
		if code >= count:
			return PackedInt32Array()  # 索引越界 → 损坏
		buf[i] = table[code]
	return buf


# ----------------------------------------------------------------------------
# varint（LEB128，仅用于 RUN 负载内部的游程长度）
# ----------------------------------------------------------------------------

static func _append_varint(out: PackedByteArray, value: int) -> void:
	var v := value
	while true:
		var b := v & 0x7F
		v >>= 7
		if v != 0:
			out.append(b | 0x80)
		else:
			out.append(b)
			return


## varint 读取：返回 [值, 新位置]；损坏时返回 [-1, pos]。
## 不用静态状态，避免线程间串扰（编解码可能在 WorkerThreadPool 中并发调用）。
static func _read_varint(buf: PackedByteArray, pos: int) -> Array:
	var result := 0
	var shift := 0
	var p := pos
	while p < buf.size():
		var b := buf[p]
		p += 1
		result |= (b & 0x7F) << shift
		if (b & 0x80) == 0:
			return [result, p]
		shift += 7
		if shift > 35:
			return [-1, pos]
	return [-1, pos]
