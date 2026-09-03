@tool
class_name TownParcelStep extends TownStepDef
## 地块细分 — 街区递归交替切片；必须临街，广场格跳过

## 街区面积超过此值则继续切分
@export_range(16, 1024, 4) var max_block_area := 260
## 小于此面积的街区碎块忽略
@export_range(4, 128, 1) var min_block_area := 32
## 地块面积上限（超过则继续切）
@export_range(16, 512, 2) var lot_max_area := 60
## 地块面积下限（小于丢弃转绿地）
@export_range(4, 64, 1) var lot_min_area := 18
## 地块最短边（格）：切分时保证两半沿切轴都不窄于此值，防细条地块
@export_range(1, 8, 1) var lot_min_edge := 2


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_parcel_step(self, ctx)
