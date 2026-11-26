@tool
class_name QVoxelFrame
extends RefCounted
## 动画的一帧 —— 「该模型在该时刻的**一整套块表**」+ 本帧时长（QVoxelSpec §12.1）。

## 本帧时长（毫秒）。
var duration_ms := 0

## 本帧的完整块表：块坐标（Vector3i）→ PackedInt32Array(B³，块内 ZXY，值 = 材质 ID，0 = 空）。
var blocks: Dictionary = {}

## 空帧判定（块表空即空，O(1)）。
func is_empty() -> bool:
	return blocks.is_empty()

## 已分配块数。
func block_count() -> int:
	return blocks.size()

## 独立副本。
func clone() -> QVoxelFrame:
	var f := QVoxelFrame.new()
	f.duration_ms = duration_ms
	for k: Vector3i in blocks:
		f.blocks[k] = (blocks[k] as PackedInt32Array).duplicate()
	return f

## 已分配块坐标（按 x → y → z 排序）。
func block_keys() -> Array[Vector3i]:
	return QVoxelBlockCodec.sorted_keys(blocks)

# 与格式层（QVoxelFile 的传输结构）互转

## 传输结构 → 帧。
static func from_dict(d: Variant) -> QVoxelFrame:
	var f := QVoxelFrame.new()
	if not (d is Dictionary):
		return f
	var src: Dictionary = d
	f.duration_ms = maxi(0, int(src.get(QVoxelSpec.ANIM_FRAME_DURATION_KEY, 0)))
	var b: Variant = src.get("blocks")
	f.blocks = b if b is Dictionary else {}
	return f

## 帧 → 传输结构。
func to_dict() -> Dictionary:
	return {QVoxelSpec.ANIM_FRAME_DURATION_KEY: duration_ms, "blocks": blocks}
