@tool
class_name RoadDef extends PCGGeneratorDef
## 道路网生成器 — 生成枢纽点，用 L 型走廊连接成网
##
## 枢纽点可自随机生成，也可从管线其它生成器（如城镇点集）取；
## mst_only=true 时用最小生成树连接（避免道路冗余交错）。

@export var region_size := Vector2(96, 96)
@export_range(2, 30, 1) var hub_count := 5
## 道路宽度（格）
@export_range(1, 4, 1) var road_width := 1
## 可选：叠加到管线的哪个栅格（在其上把道路格标为 road_value）
@export var terrain_key := ""
## 栅格中的道路格值
@export var road_value := 3
## 可选：从管线其它生成器取枢纽点（PackedVector2Array，如城镇）
@export var hubs_key := ""
## true=最小生成树连接（稀疏道路网）；false=按顺序依次连接
@export var mst_only := false

func generate(ctx: PCGContext) -> void:
	var hubs := PackedVector2Array()
	if not hubs_key.is_empty():
		var h = ctx.get_result(hubs_key)
		if h is PackedVector2Array:
			hubs = h
	var roads := PCGTool.generate_road(self, ctx.rng, hubs)
	var grid: GeneratedGrid = ctx.get_result(terrain_key) if not terrain_key.is_empty() else null
	if grid and not terrain_key.is_empty():
		PCGTool.stamp_path(grid, roads, road_value, road_width)
	ctx.output[_effective_key()] = roads

func get_desc(_data) -> String:
	return "道路 %d 枢纽" % hub_count

func _to_string() -> String:
	return name
