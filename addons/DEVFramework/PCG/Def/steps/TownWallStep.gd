@tool
class_name TownWallStep extends TownStepDef
## 城墙+城门 — 沿环路外包一圈写墙体（build 层墙值，复用地形回写与渲染语义）：
##   · 主街与城墙相交处必开城门；另按 extra_gates 开小门（选次街相交点）
##   · 城门位置记录到 layout.gates（NPC 进出/商队锚点）
##   · 四角记塔楼位 layout.wall_towers（数据层预留，消费方自渲染）
## 水面格不筑墙（形成天然水门/护城河缺口）。

## 主街城门之外额外开设的小门数
@export_range(0, 4, 1) var extra_gates := 1


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_wall_step(self, ctx)
