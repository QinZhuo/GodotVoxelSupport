@tool
class_name TownInteriorStep extends TownStepDef
## 室内布局 — 户型模板槽位抽家具变体 + 自由装饰散布 + 门口净空/可达性校验修复 + 院落围栏

## 家具槽位表：slot_name=模板中的槽位字符，items=该槽位可抽的家具变体
@export var furniture_tables: Array[FurnitureTableDef] = []
## 自由装饰物加权表（散布在室内剩余空地）
@export var prop_table: Array[ContentEntryDef] = []
## 每栋建筑最多散布几个装饰物
@export_range(0, 8, 1) var props_per_building := 3


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_interior_step(self, ctx)
