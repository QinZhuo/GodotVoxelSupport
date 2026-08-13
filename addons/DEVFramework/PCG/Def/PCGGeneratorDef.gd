@tool
@abstract class_name PCGGeneratorDef extends Def
## PCG 生成器基类 — 所有参与生成管线的生成器都继承它
##
## 每个生成器把结果写入 PCGContext.output，键由 output_key（或 Def 名）决定。
## 生成器之间通过 output key 互相引用（例如散布放置依赖网格结果做实体格剔除）。

## 结果在管线 output 中的键；留空则使用 Def 名
@export var output_key := ""
## 是否参与管线执行
@export var enabled := true

## 执行生成逻辑，把结果写入 ctx.output[实际键]
@abstract func generate(ctx: PCGContext) -> void

## 实际使用的输出键
func _effective_key() -> String:
	return output_key if not output_key.is_empty() else name

func get_desc(_data) -> String:
	return _effective_key()
