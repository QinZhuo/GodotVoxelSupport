@tool
class_name Grid3DGenDef extends PCGGeneratorDef
## 3D 网格生成器（体素）— 生成 3D 整数栅格（GeneratedGrid3D）
##
## 支持：地表地形（按 2D 噪声做高度图拉伸）+ 3D 细胞洞穴（26 邻域平滑）。
## 生成结果写入管线 output[key]，值为 GeneratedGrid3D。

enum Type {
	## 地表：每 (x,z) 列按噪声高度填充实体（Minecraft 式地表）
	NOISE_SURFACE,
	## 3D 细胞自动机洞穴
	CAVE_3D,
	## 3D WFC 波函数坍缩（六面 socket 瓦片，需配置 tile_set3d）
	WFC_3D,
	## 3D 噪声洞穴（3D 噪声阈值，offset 世界坐标 → 跨 chunk 连续）
	CAVE_NOISE_3D,
}

@export var type: Type = Type.NOISE_SURFACE
@export_range(4, 128, 1) var width := 32
@export_range(4, 128, 1) var height := 32
@export_range(4, 128, 1) var depth := 32
## 实体格值
@export var solid_value := 1
## 空格值
@export var empty_value := 0

## NOISE_SURFACE: 2D 高度噪声层（决定地表起伏）
@export var noise_layer: NoiseLayerDef
## NOISE_SURFACE: 基础高度（占高度比例 0..1）
@export_range(0.0, 1.0, 0.01) var base_height := 0.5
## NOISE_SURFACE: 高度起伏振幅（格）
@export_range(1.0, 40.0, 1.0) var height_amp := 8.0
## NOISE_SURFACE: 世界坐标偏移（分块世界用于全局采样，保证相邻 chunk 地表连续）
@export var offset := Vector3i.ZERO
## NOISE_SURFACE: 地表噪声种子（0=用生成 rng seed；非 0=固定种子，分块世界所有 chunk 用同一种子 + offset 保证全局连续）
@export var noise_seed := 0

## CAVE_3D: 初始实体占比
@export_range(0.0, 1.0, 0.01) var cave_ratio := 0.42
## CAVE_3D: 平滑迭代次数（26 邻域）
@export_range(1, 12, 1) var smooth_passes := 3
## CAVE_3D: 边界视为实体
@export var border_solid := true

## CAVE_NOISE_3D: 3D 噪声洞穴阈值（噪声采样 > 阈值 为洞穴=空，越小洞穴越多）
@export_range(0.0, 1.0, 0.01) var cave_threshold := 0.55

## WFC_3D: 3D 瓦片集（TileSetDef3D）
@export var tile_set3d: TileSetDef3D
## WFC_3D: 回溯上限（矛盾时回退重选）
@export_range(0, 100, 1) var wfc_max_backtracks := 8
## WFC_3D: 整体重试次数
@export_range(0, 20, 1) var wfc_retries := 3
## WFC_3D: 静态固定格（"x,y,z" → 瓦片索引），生成时自动遵守；运行时可用 generate_grid_3d 的 fixed 参数叠加
@export var wfc_fixed_cells: Dictionary = {}

func generate(ctx: PCGContext) -> void:
	var grid := PCGTool.generate_grid_3d(self, ctx.rng)
	ctx.output[_effective_key()] = grid

func get_desc(_data) -> String:
	return "%s %dx%dx%d" % [Type.keys()[type], width, height, depth]

func _to_string() -> String:
	return name
