@tool
class_name TownStreetStep extends TownStepDef
## 街具 — 路灯/垃圾桶沿主干道与环路间隔取样贴路边；长椅沿广场临路边缘；公交站沿干道

## 路灯间隔（格）
@export_range(2, 16, 1) var streetlamp_spacing := 6
## 垃圾桶间隔（格）
@export_range(4, 24, 1) var bin_spacing := 9
## 公交站间隔（格）
@export_range(8, 32, 1) var bus_stop_spacing := 18
## 广告牌间隔（格）
@export_range(16, 64, 2) var adboard_spacing := 32


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_street_step(self, ctx)
