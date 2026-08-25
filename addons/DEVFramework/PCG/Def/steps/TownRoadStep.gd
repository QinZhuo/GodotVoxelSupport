@tool
class_name TownRoadStep extends TownStepDef
## S2 道路网 — 主街(坡度A*→Octilinear简化→边缘枢纽) + 次街扰动垂直生长

@export_range(1, 4, 1) var main_width := 2
## 次街生长点沿主街的最小/最大间距（格）
@export_range(3, 24, 1) var street_spacing_min := 5
@export_range(4, 32, 1) var street_spacing_max := 9
## 次街最大长度（步）
@export_range(6, 128, 1) var secondary_max_len := 56
## 次街随机弯折概率（转向后锁定 street_min_run 直行）
@export_range(0.0, 1.0, 0.01) var street_wander := 0.3
## 主街代价扰动幅度（path perturbation，平地也能自然弯曲）
@export_range(0.0, 2.0, 0.05) var main_jitter := 0.4
## 坡度代价系数：cost = 1 + k*Δh²
@export_range(0.0, 4.0, 0.05) var slope_cost_k := 1.5
## 允许跨水架桥
@export var bridge_allowed := true
## 跨水额外代价
@export_range(1.0, 64.0, 0.5) var bridge_cost := 10.0
## Octilinear 简化最小段长（格）
@export_range(4, 24, 1) var road_min_segment := 8
## 次街转向后最少直行格数
@export_range(1, 16, 1) var street_min_run := 10


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_roads_step(self, ctx)
