@tool
class_name ContentGenDef extends PCGGeneratorDef
## 内容生成器 — 生成一组内容条目（加权表抽取 / 名字合成 / 马尔可夫文本）

enum Mode {
	## 加权表抽取（按 weight 概率有放回抽样）
	WEIGHTED,
	## 名字合成（前缀 + 后缀）
	NAME,
	## 词级马尔可夫文本
	MARKOV,
	## 词缀组合（基础词 + 随机前缀/后缀修饰）
	AFFIX,
}

@export var mode: Mode = Mode.WEIGHTED
@export_range(1, 1000, 1) var count := 10

## WEIGHTED: 加权表
@export var entries: Array[ContentEntryDef] = []
## NAME: 前缀 / 后缀
@export var prefixes: PackedStringArray = []
@export var suffixes: PackedStringArray = []
## MARKOV: 语料（句子数组，按空格分词）
@export var corpus: PackedStringArray = []
@export_range(1, 6, 1) var markov_order := 2
@export_range(3, 300, 1) var markov_words := 30
## AFFIX: 基础词 / 前缀词缀 / 后缀词缀
@export var affix_bases: PackedStringArray = []
@export var affix_prefixes: PackedStringArray = []
@export var affix_suffixes: PackedStringArray = []
## AFFIX: 出现前缀 / 后缀的概率
@export_range(0.0, 1.0, 0.01) var affix_prefix_chance := 0.6
@export_range(0.0, 1.0, 0.01) var affix_suffix_chance := 0.6

func generate(ctx: PCGContext) -> void:
	ctx.output[_effective_key()] = PCGTool.generate_content(self, ctx.rng)

func get_desc(_data) -> String:
	return "%s x%d" % [Mode.keys()[mode], count]

func _to_string() -> String:
	return name
