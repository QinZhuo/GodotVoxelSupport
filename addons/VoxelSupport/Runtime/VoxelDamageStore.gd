class_name VoxelDamageStore
extends RefCounted

## 逐体素累计伤害账：chunk_key -> PackedFloat32Array(CHUNK_VOLUME)。
## 【为什么归数据层而不是破坏节点】这是**体素相邻状态**：必须与 chunk 缓冲同生共死
## （卸载 / 清空 / origin shift / 载荷重建都要同步处理）。放在破坏节点上时无人负责清理，
## 于是残留伤害会"继承"给后来放上去的新体素（一放上去就被秒杀），且随卸载无限增长。
## 破坏节点只负责"发起伤害"，经 QVoxelSource 的转发读写这里。
## 【缓冲契约】与 chunk 密集缓冲同款：整块 PackedFloat32Array 供原生批量接口直接读写
## （原生在本地副本上改，调用方 write_back 写回），不做逐体素字典查询。
## 【线程约定】只在主线程访问，不交给 worker，故不参与只读快照的写时分叉。

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


## 平移全部键（origin shift）。伤害账以 chunk 为键，漏平移会让它与数据基准脱节
## （残留旧坐标条目 → 平移后旧位置仍有伤害、新位置反而没有）。
func shift(offset: Vector3i) -> void:
	_buffers = VoxelChunk.shift_key_dict(_buffers, offset)


## 清零单个体素位置的伤害（体素被移除**或被覆盖**时调用）。
## 少了这一步，该位置的残留伤害会"继承"给后来放上去的新体素 → 新体素一放上去就被秒杀。
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
## positions 可为 Array[Vector3i]，也可为原生内核返回的 PackedVector3Array ——
## 两者都暴露 x/y/z，故按分量构造，避免依赖具体元素类型。
func clear_at_bulk(positions: Variant) -> void:
	if _buffers.is_empty() or positions == null:
		return
	for p in positions:
		clear_at(Vector3i(int(p.x), int(p.y), int(p.z)))
