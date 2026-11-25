@tool
class_name VoxelVolume
extends RefCounted
## 密集体积的**布局约定**（唯一权威）—— 一维下标与三维坐标的换算。
## 【为什么单独成类】这是全项目共用的"一块体素怎么存成一维数组"的约定，消费方包括
## 求值引擎、`.vox` 导出、自定义笔刷等。约定必须只有一份，否则某个轴的错位不会报错、
## 只在跨工具时暴露。布局：**x 连续，再 y，再 z**（`i = x + y*gx + z*gx*gy`）。


## 三维坐标 → 一维下标。
static func index_of(x: int, y: int, z: int, size: Vector3i) -> int:
	return x + y * size.x + z * size.x * size.y


## 全空体积（长度对齐 size）。非正尺寸返回空数组。
static func empty(size: Vector3i) -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(maxi(size.x * size.y * size.z, 0))
	return v
