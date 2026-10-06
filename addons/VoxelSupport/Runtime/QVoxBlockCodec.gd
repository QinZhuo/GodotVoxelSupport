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
##
## 编解码一览：
##   EMPTY   0  保留值，永不写入文件（空块 = 块坐标缺失）
##   SOLID   1  负载 = 一个值（单通道时 2 字节）
##   RUN     2  uint32 count + count×(varint 游程长度, 值)
##   DENSE   3  N × bpp/8 字节，ZXY 顺序
##   INDEXED 4  uint8 n + n 个材质索引 + N×⌈log₂n⌉ 位
##
## 【分工】打包（选 codec + 出字节）在原生（约 0.2ms/块；GDScript 版混合值块约 15ms）；
## 解包留在此处作为独立参考实现，正好给 test_qvox_format 的编解码往返做 oracle。
## 字节布局权威在 QVoxSpec / docs/QVOX_FORMAT.md，本类不定义格式。


# ----------------------------------------------------------------------------
# 编解码选择 / 打包（薄封装原生实现）
# ----------------------------------------------------------------------------

## 挑选 codec 并直接产出负载（**一次完成**）。返回 {codec:int, payload:PackedByteArray}。
## 热路径（落盘 / LOD CACH pack）应直接用本函数，避免 pick + pack 扫两趟。
static func choose_and_pack(buf: PackedInt32Array, n: int) -> Dictionary:
	return NativeLoader.choose_and_pack(buf, n)


## 为一个块缓冲挑选体积最小的编解码，返回 [codec, payload_bytes]。
## EMPTY 返回 [CODEC_EMPTY, 0]（调用方据此跳过——空块不写入文件）。
## 保留此接口只为"顺序调用 pick → pack"的老写法与测试可读性；热路径请用 choose_and_pack。
static func pick_codec(buf: PackedInt32Array, n: int) -> Array:
	var picked := choose_and_pack(buf, n)
	var codec: int = picked.get("codec", QVoxSpec.CODEC_EMPTY)
	var payload: PackedByteArray = picked.get("payload", PackedByteArray())
	return [codec, payload.size()]


## 按 codec 打包块缓冲，返回负载字节（PackedByteArray）。
static func pack(codec: int, buf: PackedInt32Array, n: int) -> PackedByteArray:
	return NativeLoader.pack_with_codec(codec, buf, n)


# ----------------------------------------------------------------------------
# 解包（参考实现）
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
# 位宽（打包端在原生，解包端用它还原索引位宽）
# ----------------------------------------------------------------------------

## 表示 value 需要的最少位数（value ≥ 1；value=1 用 1 位）。
static func _bits_for(value: int) -> int:
	var bits := 0
	var v := value - 1
	while v > 0:
		bits += 1
		v >>= 1
	return maxi(bits, 1)


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
