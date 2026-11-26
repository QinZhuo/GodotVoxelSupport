class_name VoxelDamageStore
extends RefCounted

## 逐体素累计伤害账：chunk_key -> PackedFloat32Array(CHUNK_VOLUME)。

## chunk_key -> PackedFloat32Array(CHUNK_VOLUME)
var _buffers: Dictionary = {}

## 原始字典（**仅供原生批量接口直接读写**，与 _chunk_buffers_view 同契约）
func buffers() -> Dictionary:
	return _buffers

## 写回原生伤害内核修改过的缓冲（原生在本地副本上改，契约同 remove_voxels_bulk 的 buffers 回写）
func write_back(changed: Dictionary) -> void:
	for ck in changed:
		_buffers[ck] = changed[ck]

## 取某 chunk 的伤害缓冲（不存在返回空数组）
func get_chunk(chunk_key: Vector3i) -> PackedFloat32Array:
	var buf: Variant = _buffers.get(chunk_key)
	return buf if buf != null else PackedFloat32Array()

## 丢弃某 chunk 的伤害账（chunk 卸载 / 被清空时调用，防无界增长）
func erase_chunk(chunk_key: Vector3i) -> void:
	_buffers.erase(chunk_key)

## 清空全部伤害账（世界级重置 / 载荷重建用）
func clear_all() -> void:
	_buffers.clear()

## 账本是否为空（调用方据此做空表早退守卫，避免无谓遍历）
func is_empty() -> bool:
	return _buffers.is_empty()

## 平移全部键（origin shift）。
func shift(offset: Vector3i) -> void:
	_buffers = VoxelChunk.shift_key_dict(_buffers, offset)

## 清零单个体素位置的伤害（体素被移除**或被覆盖**时调用）。
func clear_at(pos: Vector3i) -> void:
	if _buffers.is_empty():
		return
	var ck := VoxelChunk.chunk_of(pos)
	var buf: Variant = _buffers.get(ck)
	if buf == null:
		return
	var local := pos - VoxelChunk.origin_of(ck)
	var arr: PackedFloat32Array = buf
	arr[VoxelChunk.buf_index(local.x, local.y, local.z)] = 0.0
	_buffers[ck] = arr

## 清零若干体素位置的累计伤害（体素被移除后调用）。
func clear_at_bulk(positions: Variant) -> void:
	if _buffers.is_empty() or positions == null:
		return
	for p in positions:
		clear_at(Vector3i(int(p.x), int(p.y), int(p.z)))
