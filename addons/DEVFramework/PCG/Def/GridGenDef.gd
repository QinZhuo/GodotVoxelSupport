@tool
class_name GridGenDef extends PCGGeneratorDef
## 网格生成器 — 生成 2D 整数栅格（GeneratedGrid）
##
## 支持多种算法：噪声阈值地形 / 细胞自动机洞穴 / Prim 迷宫 / 随机游走 / BSP 房间。
## 生成结果写入管线 output[key]，值为 GeneratedGrid。

enum Type {
	## 噪声阈值地形：采样噪声层，>= threshold 为实体
	NOISE_TERRAIN,
	## 细胞自动机洞穴
	CELLULAR,
	## Prim 迷宫
	MAZE,
	## 随机游走洞穴
	RANDOM_WALK,
	## BSP 分区房间 + 走廊
	BSP_ROOMS,
	## WFC 波函数坍缩（瓦片级，需配置 tile_set）
	WFC,
	## Voronoi 地块地形（随机种子点划分区域，每区域采样一次噪声）
	VORONOI,
}

@export var type: Type = Type.NOISE_TERRAIN
@export_range(8, 512, 1) var width := 64
@export_range(8, 512, 1) var height := 64
## 实体格值
@export var solid_value := 1
## 空格值
@export var empty_value := 0

## NOISE_TERRAIN: 噪声层
@export var noise_layer: NoiseLayerDef
## NOISE_TERRAIN: 实体阈值 (0..1)
@export_range(0.0, 1.0, 0.01) var threshold := 0.5

## CELLULAR: 初始墙占比
@export_range(0.0, 1.0, 0.01) var cave_ratio := 0.42
## CELLULAR: 平滑迭代次数
@export_range(1, 12, 1) var smooth_passes := 4
## CELLULAR: 边界视为墙
@export var border_solid := true

## MAZE: 环路度 (0=完美迷宫, 越大环越多)
@export_range(0.0, 1.0, 0.01) var maze_loopiness := 0.0

## RANDOM_WALK: 游走步数
@export_range(10, 100000, 1) var walk_steps := 800
## RANDOM_WALK: 是否从中心开始
@export var walk_start_center := true

## BSP_ROOMS: 递归深度
@export_range(1, 10, 1) var bsp_depth := 5
## BSP_ROOMS: 房间最小尺寸
@export_range(3, 40, 1) var room_min_size := 5
## BSP_ROOMS: 房间最大尺寸
@export_range(3, 80, 1) var room_max_size := 14
## BSP_ROOMS: 走廊宽度
@export_range(1, 5, 1) var corridor_width := 1

## WFC: 瓦片集（TileSetDef）
@export var tile_set: TileSetDef
## WFC: 每步传播最大格子数（防止极端情况死循环，0=不限制）
@export_range(0, 100000, 1) var wfc_max_propagations := 0
## WFC: 回溯上限（矛盾时回退到上一次观测重新选择，0=禁回溯直接放弃）
@export_range(0, 100, 1) var wfc_max_backtracks := 8
## WFC: 整体重试次数（回溯仍矛盾时用新随机流重新生成，0=不重试）
@export_range(0, 20, 1) var wfc_retries := 3
## WFC: 静态固定格（"x,y" → 瓦片索引），生成时自动遵守；运行时可用 PCGTool.generate_grid 的 fixed 参数叠加
@export var wfc_fixed_cells: Dictionary = {}

## VORONOI: 区域数量（种子点数）
@export_range(2, 200, 1) var voronoi_cells := 24
## VORONOI: 是否把区域边界画成实体（策略地图感）
@export var voronoi_border := false

## —— 连通性后处理 ——
## 生成后保证空区域连通（洞穴/地牢等"实体=墙/空地=可走"类算法适用，WFC 瓦片语义除外）
enum Connectivity {
	## 不处理（保持算法原始结果）
	NONE,
	## 保留最大空连通域，孤立小区域填成实体（可玩性优先）
	KEEP_LARGEST,
	## 隧道连接所有空区域到主区域（保留全部空间且全连通）
	CONNECT_ALL,
}
## 连通性后处理模式
@export var connectivity: Connectivity = Connectivity.NONE

func generate(ctx: PCGContext) -> void:
	var grid := PCGTool.generate_grid(self, ctx.rng)
	ctx.output[_effective_key()] = grid

func get_desc(_data) -> String:
	return "%s %dx%d" % [Type.keys()[type], width, height]

func _to_string() -> String:
	return name
