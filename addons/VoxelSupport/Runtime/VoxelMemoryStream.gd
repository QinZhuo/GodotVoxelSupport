class_name VoxelMemoryStream
extends VoxelStream

## 纯内存流：块数据只留在内存里，不落盘。进程退出即丢。
##
## 【用途】程序化世界的用户编辑需要一个**落脚处**：生成器只负责"造"，编辑结果必须
## 存在某个流里，才能在 chunk 被卸载后按需取回，而"存哪儿"与"怎么造"是两件独立的事。
## 典型组合：
##      generator = 噪声地形生成器（造未编辑的部分）
##      stream    = 本流（存编辑过的覆盖层，存优先 → 不会被重新生成覆盖）
## 需要跨进程保留编辑时，把 stream 换成 QVoxStream（.qvox 单文件）即可，
## generator 与上层代码一行都不用改 —— 这正是把"存"与"造"分开的收益。

## lod -> { key(Vector3i): PackedInt32Array }
var _blocks: Dictionary = {}


func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void:
	if buffer.is_empty():
		erase_chunk(chunk_key, lod)
		return
	if not _blocks.has(lod):
		_blocks[lod] = {}
	(_blocks[lod] as Dictionary)[chunk_key] = buffer.duplicate()


func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	var layer: Variant = _blocks.get(lod)
	if not (layer is Dictionary):
		return PackedInt32Array()
	var buf: Variant = (layer as Dictionary).get(chunk_key)
	# 返回副本：调用方会就地修改它，别名会让"未 save 的改动"悄悄写进流里。
	return (buf as PackedInt32Array).duplicate() if buf != null else PackedInt32Array()


func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	var layer: Variant = _blocks.get(lod)
	return layer is Dictionary and (layer as Dictionary).has(chunk_key)


func erase_chunk(chunk_key: Vector3i, lod: int = 0) -> void:
	var layer: Variant = _blocks.get(lod)
	if layer is Dictionary:
		(layer as Dictionary).erase(chunk_key)


func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var layer: Variant = _blocks.get(lod)
	if layer is Dictionary:
		for k in (layer as Dictionary):
			out.append(k)
	return out


## O(1) 计数（不构造 key 数组）。
func get_chunk_count(lod: int = 0) -> int:
	var layer: Variant = _blocks.get(lod)
	return (layer as Dictionary).size() if layer is Dictionary else 0


## 无写缓存，无需刷新。
func flush() -> void:
	pass


func get_stream_path() -> String:
	return "<memory>"
