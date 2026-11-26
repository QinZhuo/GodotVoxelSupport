@tool
@abstract
class_name VoxelStream
extends Resource

## 体素数据**存储**抽象 —— 只回答一件事：块数据存在哪儿、怎么存取。

## 保存单个 chunk/block 的数据。
@abstract
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void

## 读取单个 chunk/block 的数据。
@abstract
func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array

## 流中是否已有该 chunk/block 的数据。
@abstract
func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool

## 移除该 chunk/block 的数据（世界该处已清空，流不得残留）。
@abstract
func erase_chunk(chunk_key: Vector3i, lod: int = 0) -> void

## 获取流中所有已保存的 chunk/block key（用于恢复世界索引）。
@abstract
func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]

## 流中已存的 chunk/block 数量。
func get_chunk_count(lod: int = 0) -> int:
	return get_all_chunk_keys(lod).size()

## 本流是否承载粗层 LOD 数据（lod >= 1 的 block）。
func supports_lod_layer() -> bool:
	return false

## 刷新写入缓存（无写缓存的实现可留空）。
@abstract
func flush() -> void

## 数据存储路径描述（供调试 / HUD 显示）。
@abstract
func get_stream_path() -> String
