@tool
class_name TownSiteStep extends TownStepDef
## S1 选址 — 最大陆地连通域内评分选址（平坦/近水带宽/陆地占比）

@export_range(4, 128, 1) var site_candidates := 32
## 选址评分半径（格）
@export_range(2, 32, 1) var site_radius := 8
## 近水距离带下限（更近有被淹风险扣分）
@export_range(0, 32, 1) var water_band_min := 3
## 近水距离带上限（更远视为缺水扣分）
@export_range(4, 96, 1) var water_band_max := 24


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_site_step(self, ctx)
	ctx.layout.site = ctx.site
	ctx.layout.site_score = ctx.site_score
