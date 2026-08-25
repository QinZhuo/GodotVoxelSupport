@tool
class_name TownFarmStep extends TownStepDef
## 农田 — 距选址超过最小距离的连片空地（≥最小面积）转农田条纹区

## 距选址超过此距离的外围空地才可能转为农田（格）
@export_range(4, 64, 1) var farm_min_dist := 14
## 农田连片最小面积（格，低于则保持空地）
@export_range(8, 512, 4) var farm_min_area := 60


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_farm_step(self, ctx)
