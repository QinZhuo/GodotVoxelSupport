@tool
class_name QVoxelSelection
extends RefCounted
## 体素选区 —— 一个**轴对齐整数盒**（闭区间，体素坐标）。
##
## 【为什么是盒，而不是任意形状】体素美术里的"选一块"就是框选：用户要复制 / 移动的通常是
## 一整片方块（一个零件、一层、一段）。任意形状选择要维护逐格集合 + 边界可视化，成本高一个
## 数量级，而收益（抠出不规则形状）在格点上并不常见 —— 真要抠形状，用面笔 / 填充更快。
##
## 【为什么"空"要显式记一个标志】`lo == hi` 是合法的 1×1×1 选区，与"什么都没选"必须能区分。
## 少了这个标志，代码里"清空选区"与"选中一格"长得一模一样，粘贴 / 清空就会静默作用在意外的
## 地方 —— 那是最难查的一类 bug。
##
## 【为什么不夹进网格】本类不认识网格：它只是"用户框了哪一块"的纯值。越界由调用方
## （QVoxelEditSession）在取数 / 写入时自然丢弃，与画笔的既有语义一致。

## 选区下角（含）。
var _lo := Vector3i.ZERO
## 选区上角（含）。
var _hi := Vector3i.ZERO
var _empty := true


## 用两个角点造选区（顺序任意，内部归一化）。
static func from_corners(a: Vector3i, b: Vector3i) -> QVoxelSelection:
	var s := QVoxelSelection.new()
	s._lo = Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	s._hi = Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	s._empty = false
	return s


## 整块网格（"全选"）。网格非法时给空选区，而不是"0 到 -1"那种会被当成非空的怪值。
static func all(grid: Vector3i) -> QVoxelSelection:
	if grid.x <= 0 or grid.y <= 0 or grid.z <= 0:
		return QVoxelSelection.new()
	return from_corners(Vector3i.ZERO, grid - Vector3i.ONE)


func clear() -> void:
	_lo = Vector3i.ZERO
	_hi = Vector3i.ZERO
	_empty = true


func is_empty() -> bool:
	return _empty


func lo() -> Vector3i:
	return _lo


func hi() -> Vector3i:
	return _hi


## 选区尺寸（体素单位）。空选区返回 ZERO。
func size() -> Vector3i:
	return Vector3i.ZERO if _empty else _hi - _lo + Vector3i.ONE


## 选区**盒**覆盖的格数（不是其中有内容的格数 —— 那是 QVoxelClipboard.count()）。
func cell_count() -> int:
	if _empty:
		return 0
	var s := size()
	return s.x * s.y * s.z


func contains(p: Vector3i) -> bool:
	if _empty:
		return false
	return p.x >= _lo.x and p.y >= _lo.y and p.z >= _lo.z \
			and p.x <= _hi.x and p.y <= _hi.y and p.z <= _hi.z


## 平移一份副本（移动工具的目标盒、粘贴后的新选区都用它）。
func offset_by(delta: Vector3i) -> QVoxelSelection:
	if _empty:
		return QVoxelSelection.new()
	return from_corners(_lo + delta, _hi + delta)


func equals(other: QVoxelSelection) -> bool:
	if other == null:
		return false
	if _empty != other._empty:
		return false
	return _empty or (_lo == other._lo and _hi == other._hi)


## 状态栏 / 提示文案。空选区说"无选区"，而不是"0×0×0"（后者看着像选区坏了）。
func describe() -> String:
	if _empty:
		return "无选区"
	var s := size()
	return "选区 %d×%d×%d · %d 格" % [s.x, s.y, s.z, cell_count()]
