class_name TownGenContext extends RefCounted
## 城镇生成上下文 — TownStepDef 之间的共享读写载体
##
## 一个 TownDef 管线运行时创建一次，依次经过 steps 数组的每个步骤；
## 所有阶段产物（选址/道路/地块/建筑/动态层）都挂在这里传递。

## 总配置（值语义/尺寸/命名器等全局项）
var def: TownDef
## 地形高度场（可为 null = 平地）
var heightmap: HeightMap = null
## 基础种子（各步骤用 next_rng() 派生独立随机流）
var seed_base: int = 0
## 对外结果实体
var layout: TownLayout
## 选址点与评分（S1 产出）
var site := Vector2i.ZERO
var site_score := 0.0
## 最大陆地连通域（S1 产出，供边缘枢纽选取）
var main_cells := PackedInt32Array()
## 步骤序号（next_rng 内部递增计数）
var _slot := 0


func _init(town_def: TownDef = null, hmap: HeightMap = null, seed_base_val: int = 0) -> void:
	def = town_def
	heightmap = hmap
	seed_base = seed_base_val
	var w := town_def.width if town_def else 96
	var h := town_def.height if town_def else 96
	layout = TownLayout.new()
	layout.roads_grid = GeneratedGrid.create(w, h, 0)


## 为当前步骤派生独立 RNG（顺序稳定，可复现）
func next_rng() -> RandomNumberGenerator:
	_slot += 1
	return PCGTool.make_rng(PCGTool.derive_seed(seed_base, 10 + _slot))
