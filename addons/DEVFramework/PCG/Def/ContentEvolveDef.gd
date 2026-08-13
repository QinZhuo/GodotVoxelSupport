@tool
class_name ContentEvolveDef extends PCGGeneratorDef
## 内容进化生成器 — 遗传算法进化出高适应度的组合（如词缀装备）
##
## 每个个体 = 一个基础名 + N 个基因（从 genes 表选），适应度 = 所选基因的数值之和
## （基因数值用 ContentEntryDef.weight 表示，越高越好）。通过 选择→交叉→变异 迭代进化。

@export_range(1, 50, 1) var count := 8
@export_range(1, 200, 1) var generations := 40
@export_range(4, 200, 1) var population := 30
@export_range(0.0, 1.0, 0.01) var mutation_rate := 0.2
## 每个个体的基因数量
@export_range(1, 6, 1) var gene_count := 2
## 基础名表
@export var bases: PackedStringArray = []
## 候选基因（name 用于拼接，weight 作为数值贡献）
@export var genes: Array[ContentEntryDef] = []

func generate(ctx: PCGContext) -> void:
	ctx.output[_effective_key()] = PCGTool.evolve_content(self, ctx.rng)

func get_desc(_data) -> String:
	return "进化 %d 代" % generations

func _to_string() -> String:
	return name
