@tool
class_name QVoxelClipboard
extends RefCounted
## 体素剪贴板 —— 从选区里剪下的一小片体素（**相对坐标 + 材质**）。
##
## 【为什么只记非空格 + 相对坐标】
##   ① 相对坐标：粘贴要能落在任意位置，绝对坐标没有意义；
##   ② 只记非空格：选一个 32³ 的空选区会存 32768 个 0，而"剪了个空气"应当零代价。
## 于是剪贴板的代价恒等于"真正被剪走的体素数"，与选区多大无关。
##
## 【为什么材质必须跟着走】体素画的价值一半在配色上。只搬位置不搬材质，粘出来的东西会
## 全变成当前材质色 —— 那等于"复制"这个功能是坏的（而且用户会先怀疑自己贴错了地方）。

## 剪下来的体素坐标（**相对选区下角**）。
var _cells: Array[Vector3i] = []
## 与 _cells 一一对应的材质 ID（恒 > 0）。
var _materials := PackedInt32Array()
## 源选区的尺寸。粘贴后据此还原选区盒（用户能接着移动它），也用于报告"贴了多大一片"。
var _size := Vector3i.ZERO
var _empty := true


## 从选区里取数。`material_at` 是"取某格材质"的回调（返回 0 = 空）。
##
## 【为什么收回调，而不是直接收 QVoxelModel 或 QVoxelSource】取数来源是**显示层**（用户框的是
## 他看得见的东西，而显示层含修改器链的产出），不是手绘种子。本类不该认识其中任何一个，
## 于是只收一个取数函数 —— 谁提供数据由会话决定。
static func capture(sel: QVoxelSelection, material_at: Callable) -> QVoxelClipboard:
	var c := QVoxelClipboard.new()
	if sel == null or sel.is_empty():
		return c
	var lo := sel.lo()
	var hi := sel.hi()
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var m := int(material_at.call(Vector3i(x, y, z)))
				if m <= 0:
					continue
				c._cells.append(Vector3i(x, y, z) - lo)
				c._materials.append(m)
	c._size = sel.size()
	c._empty = c._cells.is_empty()
	return c


func clear() -> void:
	_cells.clear()
	_materials = PackedInt32Array()
	_size = Vector3i.ZERO
	_empty = true


func is_empty() -> bool:
	return _empty


## 源选区尺寸（不是"有内容的范围"—— 空行 / 空列照样占位，粘贴时相对关系不能变形）。
func size() -> Vector3i:
	return _size


func count() -> int:
	return _cells.size()


func cells() -> Array[Vector3i]:
	return _cells


func materials() -> PackedInt32Array:
	return _materials


## 粘贴后的选区盒（下角 = at）。空剪贴板返回空选区。
func target(at: Vector3i) -> QVoxelSelection:
	if _empty:
		return QVoxelSelection.new()
	return QVoxelSelection.from_corners(at, at + _size - Vector3i.ONE)


func describe() -> String:
	if _empty:
		return "剪贴板空"
	return "剪贴板 %d×%d×%d · %d 体素" % [_size.x, _size.y, _size.z, count()]
