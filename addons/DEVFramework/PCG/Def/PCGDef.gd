@tool
class_name PCGDef extends Def
## PCG 生成管线 — 按顺序执行一组生成器，共享一个 seed 派生的随机流
##
## 用法:
##   var out: Dictionary = PCGTool.generate(pcg_def)        # 使用 def.seed
##   var out: Dictionary = PCGTool.generate(pcg_def, 42)    # 覆盖种子
##   var grid: GeneratedGrid = out["terrain"]

## 基础种子（同一配置 + 同一种子必然复现）
@export var seed := 0
## 生成器管线（每个生成器用独立派生的 RNG，互不干扰且可复现）
@export var generators: Array[PCGGeneratorDef] = []

func get_desc(_data) -> String:
	return "PCG[seed=%d, %d 生成器]" % [seed, generators.size()]

func _to_string() -> String:
	return name
