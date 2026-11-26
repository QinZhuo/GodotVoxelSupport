@tool
class_name QVoxelClipboard
extends RefCounted
## 体素剪贴板 —— 从选区里剪下的一小片体素（**相对坐标 + 材质**）。

## 剪下来的体素坐标（**相对选区下角**）。
var _cells: Array[Vector3i] = []
## 与 _cells 一一对应的材质 ID（恒 > 0）。
var _materials := PackedInt32Array()
## 源选区的尺寸。
var _size := Vector3i.ZERO
var _empty := true

## 从选区里取数。
static func capture(sel: QVoxelSelection, material_at: Callable) -> QVoxelClipboard:
	var c := QVoxelClipboard.new()
	if sel == null or sel.is_empty():
		return c
	var lo := sel.lo()
	var hi := sel.hi()
	# 逐格判 sel.contains：盒形态收全部，集合形态只收被选中的那些格（不把包围盒里的空档也带走）。
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var p := Vector3i(x, y, z)
				if not sel.contains(p):
					continue
				var m := int(material_at.call(p))
				if m <= 0:
					continue
				c._cells.append(p - lo)
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

## 粘贴后的选区盒（下角 = at）。
func target(at: Vector3i) -> QVoxelSelection:
	if _empty:
		return QVoxelSelection.new()
	return QVoxelSelection.from_corners(at, at + _size - Vector3i.ONE)

func describe() -> String:
	if _empty:
		return "剪贴板空"
	return "剪贴板 %d×%d×%d · %d 体素" % [_size.x, _size.y, _size.z, count()]
