@tool
class_name QVoxelBlockCodec
extends RefCounted

## QVX 块级编解码器 —— 原生实现（VoxelSupportNative）的薄封装。
## 字节布局权威在 QVoxelSpec / docs/QVX_FORMAT.md，本类不定义格式。
## 输入 / 输出统一为 PackedInt32Array（长度 N = B³，值 = 材质ID，0 = 空），只处理单通道 material。
## 块内遍历顺序恒为 ZXY 线性下标：idx = x + y·B + z·B²（X 最快）。
## 体素 ↔ 块的坐标换算与 B³ 定义在 QVoxelSpec（那里是布局的唯一实现）。
##   EMPTY   0  保留值，永不写入文件（空块 = 块坐标缺失）
##   SOLID   1  负载 = 一个值（单通道 2 字节）
##   RUN     2  uint32 count + count×(varint 游程长度, 值)
##   DENSE   3  N × bpp/8 字节，ZXY 顺序
##   INDEXED 4  uint8 n + n 个材质索引 + N×⌈log₂n⌉ 位
## 【为什么全下沉原生】GDScript 版两端都是逐元素循环：混合值块打包约 15ms/块（原生化后约
## 0.2ms）；解码 196 块（1MB 存档）约 1s（原生化后毫秒级）。本类因此只剩转发。

## 挑选 codec 并直接产出负载（**一次完成**）。返回 {codec:int, payload:PackedByteArray}。
## 热路径（落盘 / LOD CACH pack）直接用本函数，避免 pick + pack 扫两趟。
static func choose_and_pack(buf: PackedInt32Array, n: int) -> Dictionary:
	return NativeLoader.choose_and_pack(buf, n)


## 为一个块缓冲挑选体积最小的编解码，返回 [codec, payload_bytes]。
## EMPTY 返回 [CODEC_EMPTY, 0]（调用方据此跳过——空块不写入文件）。
static func pick_codec(buf: PackedInt32Array, n: int) -> Array:
	var picked := choose_and_pack(buf, n)
	var codec: int = picked.get("codec", QVoxelSpec.CODEC_EMPTY)
	var payload: PackedByteArray = picked.get("payload", PackedByteArray())
	return [codec, payload.size()]


## 按 codec 打包块缓冲，返回负载字节（PackedByteArray）。
static func pack(codec: int, buf: PackedInt32Array, n: int) -> PackedByteArray:
	return NativeLoader.pack_with_codec(codec, buf, n)


## 按 codec 解包负载，返回长度 n 的缓冲；负载损坏返回空数组（上层据此判定为损坏块）。
static func unpack(codec: int, payload: PackedByteArray, n: int) -> PackedInt32Array:
	return NativeLoader.unpack_block(codec, payload, n)


# 块**表**（Dictionary[Vector3i, PackedInt32Array]）的通用工具
# 【为什么这些也放这里】判空与键序若在 QVoxelFile / QVoxelModel / QVoxelFrame / QVoxelWorld
# 各写一遍（判空 5 份，其中 2 份是 GDScript 逐体素循环），虽然各只三五行，但落盘字节的确定性、
# 空块回收的正确性全押在"所有实现完全一致"上 —— 任何一处漂移都不报错，只写出顺序不同/
# 空块残留的文件。故收敛成本类（Model→Format 是正向依赖）。

## 单块是否全空。**必须用原生 count(0)**：逐体素 GDScript 扫描在写盘路径上是秒级开销
## （实测 B=32 的世界级联判空从秒级降到毫秒级）。
static func is_empty_block(buf: PackedInt32Array) -> bool:
	return buf.count(0) == buf.size()


## 整张块表是否全空（按块表语义：**任何**一个块还有非零体素就非空）。
static func is_empty_table(blocks: Dictionary) -> bool:
	for k in blocks:
		var buf: Variant = blocks[k]
		if buf is PackedInt32Array and not is_empty_block(buf as PackedInt32Array):
			return false
	return true


## 块坐标的确定性升序：x → y → z。
## 【为什么必须是一个共享实现】Dictionary 迭代顺序不保证稳定，而落盘顺序、增量写的块搬运、
## 回归测试的逐字节哈希都要求"同一份数据恒得同一串字节" —— 五份内联 λ 里只要有一份写成
## y 优先，两个进程就能把同一份数据写成两份不同字节的文件。
static func key_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


## 块表的键按 key_less 排序后的数组（落盘 / 增量编码 / 快照的统一起点）。
static func sorted_keys(blocks: Dictionary) -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for k in blocks:
		if k is Vector3i:
			keys.append(k)
	keys.sort_custom(key_less)
	return keys


## 把"可能不是块表"的 Variant 收窄为块表字典（非 Dictionary → 空）。增量写盘与 ANIM 编码
## 都从无类型的外部数据（JSON / 上一版负载索引）取块表，收窄只有这一处。
static func table_of(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}
