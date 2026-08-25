@tool
## DefTable 表格网格容器(变高行 + 行虚拟化)。
## 行高由外部(View)按单元格文本预计算后传入, 本容器只负责摆位与滚动定位,
## 保证滚动范围(row_offsets)精确且不随可见行变化抖动。
class_name DefTableGrid
extends Container

## 行高最小值: set_row_heights 统一钳制, 偏移/渲染共用同一份 row_heights,
## 保证摆位与渲染高度一致, 避免单元格溢出到下一行造成重叠
const MIN_ROW_HEIGHT := 32.0

## 每列宽度
var column_widths: Array[float] = []
## 总行数
var total_rows: int = 0
## 每行高度(View 预计算)
var row_heights: Array[float] = []
## 每行起始 Y 偏移(累加行高, 供滚动定位)
var row_offsets: Array[float] = []
## 每列起始 X 偏移(累加列宽)
var column_offsets: Array[float] = []

## 列偏移: cell_pos.x 是全局列索引, 本网格从第几列开始渲染(冻结网格=0, 滚动网格=1)
var column_offset: int = 0

## 悬停高亮行(B3, -1=无): 由 View 设置; _draw 绘制在单元格之下, 与半透明斑马纹叠加
var hover_row: int = -1:
	set(v):
		if hover_row != v:
			hover_row = v
			queue_redraw()

var _cached_minimum_size := Vector2.ZERO


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		sort_children()
	elif what == NOTIFICATION_DRAW:
		_draw_hover()


func _draw_hover() -> void:
	if hover_row < 0 or hover_row >= row_heights.size():
		return
	var h: float = row_heights[hover_row]
	var y: float = row_offsets[hover_row] if hover_row < row_offsets.size() else 0.0
	var w := 0.0
	for cw in column_widths:
		w += cw
	draw_rect(Rect2(0.0, y, maxf(w, size.x), h), Color(1.0, 1.0, 1.0, 0.055))


func _get_minimum_size() -> Vector2:
	return _cached_minimum_size


## 设置列宽与总行数。row_heights 需由 set_row_heights 提供。
func configure(widths: Array[float], rows_total: int) -> void:
	column_widths = widths.duplicate()
	total_rows = rows_total
	_recompute_offsets()
	queue_sort()


## 传入预计算的行高, 刷新偏移与滚动范围。
## 在此统一钳制到 MIN_ROW_HEIGHT, 使 row_heights 与 row_offsets 口径一致
## (渲染用同一份 row_heights, 不再在 sort_children 里二次钳制)。
func set_row_heights(heights: Array[float]) -> void:
	row_heights = heights.duplicate()
	for i in row_heights.size():
		if row_heights[i] < MIN_ROW_HEIGHT:
			row_heights[i] = MIN_ROW_HEIGHT
	_recompute_offsets()
	queue_sort()


func _recompute_offsets() -> void:
	column_offsets.clear()
	var cx := 0.0
	for w in column_widths:
		column_offsets.append(cx)
		cx += w
	column_offsets.append(cx)

	row_offsets.clear()
	var cy := 0.0
	for h in row_heights:
		row_offsets.append(cy)
		cy += h
	row_offsets.append(cy)


## 行 y 坐标 -> 行索引 (变高行二分查找)
func row_index_at(y: float) -> int:
	if row_offsets.size() == 0 or y < 0.0:
		return 0
	var lo := 0
	var hi := row_offsets.size() - 2
	if hi < 0:
		return 0
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if row_offsets[mid] <= y:
			lo = mid
		else:
			hi = mid - 1
	return lo


## 由 Container 在布局时调用。
## 行容器模型: 子节点 = 行 Control(meta: row_index / cell_parked), 一次摆整行;
## 单元格是行容器的子节点, 在行内由 View 定点摆放, 不经此排序。
func sort_children() -> void:
	var ncols := column_widths.size()
	if ncols == 0:
		_cached_minimum_size = Vector2(0.0, 0.0)
		return

	var w := 0.0
	for cw in column_widths:
		w += cw
	for child in get_children():
		var c := child as Control
		if c == null:
			continue
		# 停泊中的行(已移出裁剪区)不参与摆位
		if bool(c.get_meta(&"cell_parked", false)):
			continue
		var ri := int(c.get_meta(&"row_index", -1))
		if ri < 0 or ri >= total_rows:
			continue
		var h := row_heights[ri] if ri < row_heights.size() else MIN_ROW_HEIGHT
		var y := row_offsets[ri] if ri < row_offsets.size() else 0.0
		fit_child_in_rect(c, Rect2(Vector2(0.0, y), Vector2(maxf(w, size.x), h)))

	var total_h := 0.0
	for h in row_heights:
		total_h += h
	_cached_minimum_size = Vector2(w, total_h)