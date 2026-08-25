@tool
class_name TownWardStep extends TownStepDef
## 语义分区 — 按规则把地块划入 市集/贵族/民居 分区：
##   · 市集区(market)：邻广场 2.5 倍半径内（商业密度最高，建筑填充率强制 100%）
##   · 贵族区(noble)：地块均高位于前四分位（需高度图；平地自动跳过；石砌/平顶偏好+层数+1）
##   · 民居区(common)：其余
## 结果写 parcels[i].ward 与 layout.wards 统计，由建筑步消费。


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_ward_step(self, ctx)
