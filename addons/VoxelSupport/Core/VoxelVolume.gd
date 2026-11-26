@tool
class_name VoxelVolume
extends RefCounted
## 密集体积的**布局约定**（唯一权威）—— 一维下标与三维坐标的换算。

## 三维坐标 → 一维下标。
static func index_of(x: int, y: int, z: int, size: Vector3i) -> int:
	return x + y * size.x + z * size.x * size.y

## 全空体积（长度对齐 size）。
static func empty(size: Vector3i) -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(maxi(size.x * size.y * size.z, 0))
	return v
