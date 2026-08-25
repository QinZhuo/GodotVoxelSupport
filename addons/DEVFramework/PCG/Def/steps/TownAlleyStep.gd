@tool
class_name TownAlleyStep extends TownStepDef
## 巷道细分 — 递归空间细分刻巷道，形成闭合街区（Parish&Müller 网格化）


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_alley_step(self, ctx)
