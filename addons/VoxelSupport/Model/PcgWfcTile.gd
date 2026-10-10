@tool
class_name PcgWfcTile
extends Resource

## WFC 图块 —— 一小块可拼接的体素"积木"，带六个面的接口签名（socket）。
## 【socket 是什么】每个面有一个字符串名字（如 "wall" / "open" / "floor"）。
## 两块相邻时，接触的那两个面必须**同名**才能拼接。名字是任意的——WFC 只比较相等、
## 不解释含义，于是"谁能和谁挨着"完全由作者用名字表达，算法本身零几何知识。
## 【面顺序】sockets 恒为 6 项，依次对应 +X, -X, +Y, -Y, +Z, -Z
## （与 PcgWfc.DIRS 同序，改一处必须改另一处）。
## 【尺寸】同一套 WFC 里所有图块的 size 应一致（PcgWfc 按第一个图块的尺寸排布格位）。

## 六个面的接口名（顺序见上）。缺项按空串处理（空串只与空串匹配）。
@export var sockets: PackedStringArray = PackedStringArray(["", "", "", "", "", ""])

## 图块占位尺寸（体素）。
@export var size: Vector3i = Vector3i(4, 4, 4)

## 体素内容（密集，长度 = size.x*size.y*size.z，值 = 材质ID，0 = 空），
## 下标 = x + y*size.x + z*size.x*size.y。
@export var voxels: PackedInt32Array = PackedInt32Array()

## 选择权重（越大越常被选中）—— 用它压低/抬高某类图块的出现频率。
@export var weight: float = 1.0


## 越界 / 未初始化安全的读取（尺寸不符时按空处理，不让坏数据读崩）。
func voxel_at(x: int, y: int, z: int) -> int:
	if x < 0 or y < 0 or z < 0 or x >= size.x or y >= size.y or z >= size.z:
		return 0
	var i := x + y * size.x + z * size.x * size.y
	if i < 0 or i >= voxels.size():
		return 0
	return voxels[i]


## 第 d 面的接口名（缺项按空串，便于直接比较）。
func socket_of(d: int) -> String:
	if d < 0 or d >= sockets.size():
		return ""
	return sockets[d]


## 代码构造便捷入口（在编辑器里直接填 @export 字段亦可）。
static func make(tile_size: Vector3i, voxel_data: PackedInt32Array,
		face_sockets: PackedStringArray, tile_weight: float = 1.0) -> PcgWfcTile:
	var t := PcgWfcTile.new()
	t.size = tile_size
	t.voxels = voxel_data
	t.sockets = face_sockets
	t.weight = tile_weight
	return t
