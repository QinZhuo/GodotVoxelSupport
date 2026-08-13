@tool
class_name RiverDef extends PCGGeneratorDef
## 河流生成器 — 从高地沿"梯度下降"流向低处（可叠加到已有地形栅格）
##
## 业界常见做法：沿高度场的梯度（选 8 邻域最低）一路向下直到入海，
## 配少量随机游走扰动让河道更自然。输出路径点，可选把河格标记进 terrain_key 的栅格。

@export_range(16, 512, 1) var map_width := 96
@export_range(16, 512, 1) var map_height := 96
## 高度场（决定流向；不配置则不出河）
@export var elevation_layer: NoiseLayerDef
## 河流数量
@export_range(1, 20, 1) var river_count := 3
## 河宽（格，1=单格，3=十字粗）
@export_range(1, 4, 1) var width := 1
## 低于此高度视为入海（河流结束）
@export_range(0.0, 1.0, 0.01) var sea_level := 0.35
## 最大步数（防止死循环）
@export_range(10, 2000, 10) var max_steps := 400
## 下降时随机游走概率（0=纯梯度易陷局部坑，越大越蜿蜒）
@export_range(0.0, 0.5, 0.01) var wander := 0.15

## 可选：叠加到管线的哪个栅格（在其上把河流格标为 river_value）
@export var terrain_key := ""
## 栅格中的河流格值
@export var river_value := 2

func generate(ctx: PCGContext) -> void:
	var paths := PCGTool.generate_river(self, ctx.rng)
	var grid: GeneratedGrid = ctx.get_result(terrain_key) if not terrain_key.is_empty() else null
	if grid and not terrain_key.is_empty():
		PCGTool.stamp_path(grid, paths, river_value, width)
	ctx.output[_effective_key()] = paths

func get_desc(_data) -> String:
	return "河流 x%d" % river_count

func _to_string() -> String:
	return name
