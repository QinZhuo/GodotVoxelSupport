@tool
class_name PlacementDef extends PCGGeneratorDef
## 散布放置器 — 在指定区域内生成一组点
##
## 支持泊松圆盘采样（点间距可控、无重叠）/ 抖动网格 / 均匀随机。
## 可指定依赖某个网格输出 key，把落在实体格上的点剔除（例如只在空地上放树）。

enum Mode {
	## 泊松圆盘：点间距 >= min_distance，无重叠
	POISSON_DISK,
	## 抖动网格：按数量排布均匀网格并抖动
	JITTER_GRID,
	## 均匀随机
	RANDOM_UNIFORM,
}

@export var mode: Mode = Mode.POISSON_DISK
## 目标点数（泊松模式为上限，实际由最小间距决定）
@export_range(1, 100000, 1) var count := 100
## 放置区域尺寸
@export var region_size := Vector2(256, 256)
## 泊松最小间距
@export_range(0.5, 512.0, 0.5) var min_distance := 6.0
## 泊松每点尝试次数
@export_range(1, 60, 1) var max_attempts := 30
## 抖动幅度 (0..1)
@export_range(0.0, 1.0, 0.01) var jitter := 0.5

## 依赖的网格输出 key（可选）：把落在这些值格子上的点剔除
@export var exclude_grid_key := ""
## 剔除的格子值
@export var exclude_values: PackedInt32Array = [1]

func generate(ctx: PCGContext) -> void:
	var pts := PCGTool.place(self, ctx.rng)
	var grid: GeneratedGrid = ctx.get_result(exclude_grid_key) if not exclude_grid_key.is_empty() else null
	if grid:
		pts = _filter_by_grid(pts, grid)
	ctx.output[_effective_key()] = pts

## 把区域坐标按比例映射到栅格并剔除实体格上的点
func _filter_by_grid(pts: PackedVector2Array, grid: GeneratedGrid) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		var gx := int(p.x / region_size.x * grid.width)
		var gy := int(p.y / region_size.y * grid.height)
		if not grid.in_bounds(gx, gy):
			continue
		if grid.get_cell(gx, gy) in exclude_values:
			continue
		out.append(p)
	return out

func get_desc(_data) -> String:
	return "%s x%d" % [Mode.keys()[mode], count]

func _to_string() -> String:
	return name
