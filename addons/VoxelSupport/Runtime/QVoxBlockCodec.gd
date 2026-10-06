@tool
class_name QVoxBlockCodec
extends RefCounted

## QVox 块级编解码器 —— 原生实现（VoxelNative）的薄封装。
## 字节布局权威在 QVoxSpec / docs/QVOX_FORMAT.md，本类不定义格式。
##
## 输入 / 输出统一为 PackedInt32Array（长度 N = B³，值 = 材质ID，0 = 空），只处理单通道 material。
## 块内遍历顺序恒为 ZXY 线性下标：idx = x + y·B + z·B²（X 最快）。
##
##   EMPTY   0  保留值，永不写入文件（空块 = 块坐标缺失）
##   SOLID   1  负载 = 一个值（单通道 2 字节）
##   RUN     2  uint32 count + count×(varint 游程长度, 值)
##   DENSE   3  N × bpp/8 字节，ZXY 顺序
##   INDEXED 4  uint8 n + n 个材质索引 + N×⌈log₂n⌉ 位
##
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
	var codec: int = picked.get("codec", QVoxSpec.CODEC_EMPTY)
	var payload: PackedByteArray = picked.get("payload", PackedByteArray())
	return [codec, payload.size()]


## 按 codec 打包块缓冲，返回负载字节（PackedByteArray）。
static func pack(codec: int, buf: PackedInt32Array, n: int) -> PackedByteArray:
	return NativeLoader.pack_with_codec(codec, buf, n)


## 按 codec 解包负载，返回长度 n 的缓冲；负载损坏返回空数组（上层据此判定为损坏块）。
static func unpack(codec: int, payload: PackedByteArray, n: int) -> PackedInt32Array:
	return NativeLoader.unpack_block(codec, payload, n)
