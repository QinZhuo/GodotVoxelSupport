@tool
class_name CityDef extends PCGGeneratorDef
## 城市街区生成器 — 道路网格划分街区，街区内建筑 / 公园填充
##
## 生成结果写入管线 output[key]，值为 GeneratedGrid：
##   空=街道 / road_value=道路 / building_value=建筑 / park_value=公园/广场

@export_range(16, 512, 1) var width := 96
@export_range(16, 512, 1) var height := 96
## 街区尺寸（格）
@export_range(4, 32, 1) var block_size := 12
## 道路宽度（格）
@export_range(1, 6, 1) var road_width := 2
## 建筑间留巷（街区内缩进，形成小巷/庭院）
@export_range(0, 4, 1) var building_gap := 1
## 公园/广场街区占比
@export_range(0.0, 1.0, 0.01) var park_ratio := 0.15
## 各值：道路 / 建筑 / 公园
@export var road_value := 3
@export var building_value := 1
@export var park_value := 2
## 空格值（街道）
@export var empty_value := 0

func generate(ctx: PCGContext) -> void:
	var grid := PCGTool.generate_city(self, ctx.rng)
	ctx.output[_effective_key()] = grid

func get_desc(_data) -> String:
	return "城市 %d 街区" % (ceili(width / float(block_size)) * ceili(height / float(block_size)))

func _to_string() -> String:
	return name
