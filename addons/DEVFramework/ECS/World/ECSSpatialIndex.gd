class_name ECSSpatialIndex
extends RefCounted

## ECS 空间索引 —— 网格分桶, 快速邻居查询。
## 索引里存的是**行号**(与 world.query_rows / get_column 同一套下标, 列按行取值),
## 不是实体 ID; 要实体对象请再走 world.query_entities(rows)。

var world: ECSWorld
var comp: Script          # 位置组件
var field: StringName     # 位置字段
var cell_size: float      # 网格单元大小

var _cells := {}          # "gx,gy" -> Array[行号]
var _cell_entities := {}  # 行号 -> 所在格(快速移除)
var _struct_v := -1       # 建索引时的全局结构版本
var _comp_v := -1         # 建索引时该位置组件的结构版本

## 需要世界 + 位置组件 + 位置字段 + 网格大小
func _init(p_world: ECSWorld, p_comp: Script, p_field: StringName = &"pos", p_cell_size: float = 64.0) -> void:
	world = p_world
	comp = p_comp
	field = p_field
	cell_size = maxf(p_cell_size, 1.0)

## 重建索引(实体移动后调用; 一般每帧一次)
func rebuild() -> void:
	_cells.clear()
	_cell_entities.clear()
	# 先记版本再取数据: 取的过程中若有结构变更, 下次查询会发现版本不符而重来
	_struct_v = world.struct_version()
	_comp_v = world.comp_version(comp)
	var rows: PackedInt32Array = world.query_rows(comp, [], [])
	var pos_col: PackedVector2Array = world.get_column(comp, field)
	for e in rows:
		if e >= pos_col.size():
			continue
		var key := _cell_key(pos_col[e])
		if not _cells.has(key):
			_cells[key] = []
		_cells[key].append(e)
		_cell_entities[e] = key

## 行号是 swap-remove 维护的, 结构一变(增删实体/组件)旧索引就会指向错行。
## 三个查询入口都先过这里: 版本不符就地重建, 拿到的行号永远对应当前世界。
func _ensure_fresh() -> void:
	if _struct_v != world.struct_version() or _comp_v != world.comp_version(comp):
		rebuild()


## 半径查询: 返回以 pos 为中心、radius 范围内(含 comp 组件)的**行号**数组。
func query_radius(pos: Vector2, radius: float) -> Array[int]:
	_ensure_fresh()
	var out: Array[int] = []
	var radius2 := radius * radius
	# 计算覆盖的网格范围
	var min_gx := int(floor((pos.x - radius) / cell_size))
	var max_gx := int(floor((pos.x + radius) / cell_size))
	var min_gy := int(floor((pos.y - radius) / cell_size))
	var max_gy := int(floor((pos.y + radius) / cell_size))
	var pos_col: PackedVector2Array = world.get_column(comp, field)
	for gx in range(min_gx, max_gx + 1):
		for gy in range(min_gy, max_gy + 1):
			var key := "%d,%d" % [gx, gy]
			if not _cells.has(key):
				continue
			for e in _cells[key]:
				if e >= pos_col.size():
					continue
				var d := pos_col[e].distance_squared_to(pos)
				if d <= radius2:
					out.append(e)
	return out

## 单位距离内最近实体(用于"最近敌人"逻辑)
func query_nearest(pos: Vector2, radius: float) -> int:
	var candidates := query_radius(pos, radius)
	if candidates.is_empty():
		return -1
	var pos_col: PackedVector2Array = world.get_column(comp, field)
	var best := -1
	var best_d := radius * radius
	for e in candidates:
		var d := pos_col[e].distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = e
	return best

## 快速最近实体: 只查所在格及相邻 8 格(比 query_nearest 的半径扫描快)。
func query_cell_nearest(pos: Vector2, max_dist: float, exclude: int = -1) -> int:
	_ensure_fresh()
	var pos_col: PackedVector2Array = world.get_column(comp, field)
	var best := -1
	var best_d := max_dist * max_dist
	var cx := int(floor(pos.x / cell_size))
	var cy := int(floor(pos.y / cell_size))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := "%d,%d" % [cx + dx, cy + dy]
			if not _cells.has(key):
				continue
			for e in _cells[key]:
				if e == exclude or e >= pos_col.size():
					continue
				var d := pos_col[e].distance_squared_to(pos)
				if d < best_d:
					best_d = d
					best = e
	return best

## 网格 key
func _cell_key(p: Vector2) -> String:
	var gx := int(floor(p.x / cell_size))
	var gy := int(floor(p.y / cell_size))
	return "%d,%d" % [gx, gy]
