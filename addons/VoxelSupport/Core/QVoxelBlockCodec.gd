@tool
class_name QVoxelBlockCodec
extends RefCounted

## QVX 块级编解码器 —— 原生实现（VoxelSupportNative）的薄封装。

## 挑选 codec 并直接产出负载（**一次完成**）。
static func choose_and_pack(buf: PackedInt32Array, n: int) -> Dictionary:
	return NativeLoader.choose_and_pack(buf, n)

## 为一个块缓冲挑选体积最小的编解码，返回 [codec, payload_bytes]。
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

## 单块是否全空。
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

## 把"可能不是块表"的 Variant 收窄为块表字典（非 Dictionary → 空）。
static func table_of(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}
