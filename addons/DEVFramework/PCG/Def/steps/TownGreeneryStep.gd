@tool
class_name TownGreeneryStep extends TownStepDef
## 绿化 — 城镇空地泊松式树木散布 + 沿主街行道树

## 树木数量上限（空地散布，实际受空地与间距约束）
@export_range(0, 600, 5) var tree_count := 140
## 树木最小间距（格）
@export_range(1.0, 8.0, 0.5) var tree_min_distance := 2.5
## 行道树沿主街的间隔（格；0=不种行道树）
@export_range(0, 16, 1) var street_tree_spacing := 5


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_greenery_step(self, ctx)
