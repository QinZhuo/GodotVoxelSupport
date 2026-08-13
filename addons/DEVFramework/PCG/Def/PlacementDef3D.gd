@tool
class_name PlacementDef3D extends PCGGeneratorDef
## 3D 散布放置器 — 在 3D 空间生成点集（树/石头/建筑等）
##
## 支持 3D 泊松圆盘（点间距可控无重叠）/ 抖动网格 / 均匀随机。
## 可指定依赖某个 3D 网格输出 key，剔除落在实体格内的点。

enum Mode {
	## 3D 泊松圆盘：点间距 >= min_distance，无重叠
	POISSON_3D,
	## 3D 抖动网格：按数量排布均匀网格并抖动
	JITTER_GRID_3D,
	## 3D 均匀随机
	RANDOM_3D,
}

@export var mode: Mode = Mode.POISSON_3D
## 目标点数（泊松为上限）
@export_range(1, 100000, 1) var count := 100
## 放置区域尺寸
@export var region_size := Vector3(64, 32, 64)
## 泊松最小间距
@export_range(0.5, 128.0, 0.5) var min_distance := 4.0
## 泊松每点尝试次数
@export_range(1, 60, 1) var max_attempts := 30
## 抖动幅度 (0..1)
@export_range(0.0, 1.0, 0.01) var jitter := 0.5

## 依赖的 3D 网格输出 key（可选）：剔除落在实体格内的点
@export var exclude_grid3d_key := ""
## 剔除的格子值（实体值）
@export var exclude_values: PackedInt32Array = [1]

func generate(ctx: PCGContext) -> void:
	var pts := PCGTool.place_3d(self, ctx.rng)
	var grid3d: GeneratedGrid3D = ctx.get_result(exclude_grid3d_key) if not exclude_grid3d_key.is_empty() else null
	if grid3d:
		pts = _filter_by_grid(pts, grid3d)
	ctx.output[_effective_key()] = pts

## 把区域坐标按比例映射到 3D 栅格并剔除实体格内的点
func _filter_by_grid(pts: PackedVector3Array, grid: GeneratedGrid3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in pts:
		var gx := int(p.x / region_size.x * grid.width)
		var gy := int(p.y / region_size.y * grid.height)
		var gz := int(p.z / region_size.z * grid.depth)
		if not grid.in_bounds(gx, gy, gz):
			continue
		if grid.get_cell(gx, gy, gz) in exclude_values:
			continue
		out.append(p)
	return out

func get_desc(_data) -> String:
	return "3D %s x%d" % [Mode.keys()[mode], count]

func _to_string() -> String:
	return name
