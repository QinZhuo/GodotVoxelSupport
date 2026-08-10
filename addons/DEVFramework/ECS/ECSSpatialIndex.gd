class_name ECSSpatialIndex
extends RefCounted

## ECS 空间索引 —— 网格分桶, 快速邻居查询。
##
## 用途: 战斗范围检测 / 视野判断 / 寻路邻居搜索。
## 比全量遍历快: 将实体按网格分桶, 查询时只检查相邻桶。
##
## 用法:
##   var idx := ECSSpatialIndex.new(world, ECSDemoMoveComponent, &"pos", 64.0)
##   idx.rebuild()                              # 每帧(或实体移动后)重建
##   var nearby := idx.query_radius(pos, 100.0)  # 半径内实体 ID

var world: ECSWorld
var comp: Script          # 位置组件
var field: StringName     # 位置字段
var cell_size: float      # 网格单元大小

var _cells := {}          # "gx,gy" -> Array[实体ID]
var _cell_entities := {}  # 实体ID -> 所在格(快速移除)

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

## 半径查询: 返回以 pos 为中心、radius 范围内(可能含 comp 组件)的实体 ID 数组。
func query_radius(pos: Vector2, radius: float) -> Array[int]:
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

## 快速最近实体: 只查所在格及相邻 8 格(比 query_nearest 的半径扫描快,
## 适合"找同区域敌人"场景)。radius 用于二次距离过滤。
## exclude: 排除的实体 ID(通常是自身, 避免找到自己)。
func query_cell_nearest(pos: Vector2, max_dist: float, exclude: int = -1) -> int:
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
