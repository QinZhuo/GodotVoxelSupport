@tool
class_name TemplateStitchDef extends PCGGeneratorDef
## 模板拼接生成器 — 随机放置多个手作模板，用走廊连接成关卡
##
## 模板可用 TemplateDef 定义（字符串行），随机尝试放置（不重叠），
## 可选在模板中心之间挖走廊。适合做地牢房间组合 / 建筑群。

@export_range(16, 512, 1) var width := 64
@export_range(16, 512, 1) var height := 64
## 模板表（按 weight 加权抽取）
@export var templates: Array[TemplateDef] = []
## 放置数量
@export_range(1, 50, 1) var count := 5
## 模板间最小间距（格，0=可紧邻）
@export_range(0, 10, 1) var min_gap := 1
## 是否用走廊连接各模板中心
@export var connect := true
## 走廊宽度
@export_range(1, 5, 1) var corridor_width := 1
## 空格值 / 实体格值（画走廊时用实体值之外的边）
@export var empty_value := 0
@export var solid_value := 1

func generate(ctx: PCGContext) -> void:
	var grid := PCGTool.generate_template_stitch(self, ctx.rng)
	ctx.output[_effective_key()] = grid

func get_desc(_data) -> String:
	return "拼接 %d 模板" % count

func _to_string() -> String:
	return name
