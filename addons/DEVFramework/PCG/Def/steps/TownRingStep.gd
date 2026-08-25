@tool
class_name TownRingStep extends TownStepDef
## 边界环路 — 沿道路覆盖范围外圈刻一圈路收束路网；触地图边缘侧自然开口作城门


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_ring_step(self, ctx)
