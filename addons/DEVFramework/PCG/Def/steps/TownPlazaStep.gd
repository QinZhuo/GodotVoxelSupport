@tool
class_name TownPlazaStep extends TownStepDef
## 广场 — 选址周围空地划为广场并记录中心设施

## 广场半径（格）
@export_range(0, 12, 1) var plaza_radius := 4
## 中心设施名（水井/喷泉…，记入 layout.plaza_item；空=无设施）
@export var plaza_feature := "水井"


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_plaza_step(self, ctx)
