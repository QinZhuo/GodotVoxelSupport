@tool
class_name QVoxelSelection
extends RefCounted
## 体素选区 —— 支持两种形态：**轴对齐整数盒**（框选）与**逐格集合**（快速连通选区）。
## 【为什么要有逐格集合】框选出来的是矩形，落笔明确；而"快速选区"挑的是连通的一块，形状往往
## 不规则 —— 若退化成包围盒，就会把框里那些本来没选中的体素一起搬走/清掉。集合形态如实记录
## 到底选了哪几格，移动 / 复制 / 清空都只作用于这些格。
## 【为什么保留盒形态】框选是矩形这一事实无需逐格存；盒形态还能让"全选 / 拖动框选"零开销，
## 显示上画一个框也比画几千条线清楚。
## 【空要显式记标志】`lo == hi` 是合法的 1×1×1 选区，与"什么都没选"必须区分。

const _MIN := Vector3i(-2147483648, -2147483648, -2147483648)
const _MAX := Vector3i(2147483647, 2147483647, 2147483647)

## 选区包围盒（含）。盒形态 = 全部；集合形态 = 逐格集合的包围盒（供显示 / 移动原点用）。
var _lo := Vector3i.ZERO
var _hi := Vector3i.ZERO
var _empty := true
## 集合形态：逐格真值（Vector3i → true）。盒形态为空字典。
var _cells := {}


## 盒形态：用两个角点造选区（顺序任意，内部归一化）。
static func from_corners(a: Vector3i, b: Vector3i) -> QVoxelSelection:
	var s := QVoxelSelection.new()
	s._lo = Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	s._hi = Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	s._empty = false
	return s


## 集合形态：用一批格点造选区（去重、算包围盒）。空集合返回空选区。
static func from_cells(cells: Array) -> QVoxelSelection:
	var s := QVoxelSelection.new()
	var lo := _MAX
	var hi := _MIN
	for c in cells:
		var p: Vector3i = c
		s._cells[p] = true
		lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
		hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
	if s._cells.is_empty():
		return QVoxelSelection.new()
	s._lo = lo
	s._hi = hi
	s._empty = false
	return s


## 整块网格（"全选"）。网格非法时给空选区。
static func all(grid: Vector3i) -> QVoxelSelection:
	if grid.x <= 0 or grid.y <= 0 or grid.z <= 0:
		return QVoxelSelection.new()
	return from_corners(Vector3i.ZERO, grid - Vector3i.ONE)


func is_empty() -> bool:
	return _empty


## 是否逐格集合形态（快速选区）。
func is_precise() -> bool:
	return not _cells.is_empty()


func lo() -> Vector3i:
	return _lo


func hi() -> Vector3i:
	return _hi


## 包围盒尺寸（盒形态即选区尺寸；集合形态为其包围盒尺寸）。
func size() -> Vector3i:
	return Vector3i.ZERO if _empty else _hi - _lo + Vector3i.ONE


## 选区实际包含的格数（集合形态 = 集合大小；盒形态 = 盒体积）。
func cell_count() -> int:
	if _empty:
		return 0
	if is_precise():
		return _cells.size()
	var s := size()
	return s.x * s.y * s.z


func contains(p: Vector3i) -> bool:
	if _empty:
		return false
	if is_precise():
		return _cells.has(p)
	return p.x >= _lo.x and p.y >= _lo.y and p.z >= _lo.z \
		and p.x <= _hi.x and p.y <= _hi.y and p.z <= _hi.z


## 逐格集合（盒形态时展开成盒内全部格）。
func cells() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if _empty:
		return out
	if is_precise():
		for k: Vector3i in _cells:
			out.append(k)
		return out
	var s := size()
	for z in s.z:
		for y in s.y:
			for x in s.x:
				out.append(_lo + Vector3i(x, y, z))
	return out


## 平移一份副本（移动工具的目标盒、粘贴后的新选区都用它）。
func offset_by(delta: Vector3i) -> QVoxelSelection:
	if _empty:
		return QVoxelSelection.new()
	if is_precise():
		var moved: Array[Vector3i] = []
		for k: Vector3i in _cells:
			moved.append(k + delta)
		return from_cells(moved)
	return from_corners(_lo + delta, _hi + delta)


## 并集（Shift 加选）：返回一个逐格集合并入 other 的**新**选区。
func union_with(other: QVoxelSelection) -> QVoxelSelection:
	var set := {}
	for c in cells():
		set[c] = true
	for c in other.cells():
		set[c] = true
	return from_cells(set.keys())


## 差集（Ctrl 减选）：从自身逐格集合里去掉 other 的格。
func subtract(other: QVoxelSelection) -> QVoxelSelection:
	var drop := {}
	for c in other.cells():
		drop[c] = true
	var keep: Array[Vector3i] = []
	for c in cells():
		if not drop.has(c):
			keep.append(c)
	return from_cells(keep)


func equals(other: QVoxelSelection) -> bool:
	if other == null:
		return false
	if _empty != other._empty:
		return false
	if _empty:
		return true
	if is_precise() != other.is_precise():
		return false
	if is_precise():
		if _cells.size() != other._cells.size():
			return false
		for k: Vector3i in _cells:
			if not other._cells.has(k):
				return false
		return true
	return _lo == other._lo and _hi == other._hi


## 状态栏 / 提示文案。空选区说"无选区"；集合形态报实际格数。
func describe() -> String:
	if _empty:
		return "无选区"
	var s := size()
	return "选区 %d×%d×%d · %d 格" % [s.x, s.y, s.z, cell_count()]
