@tool
class_name TownConformStep extends TownStepDef
## V1 地形回写（cut & fill）— 道路限坡松弛 + 广场/建筑切台锚点 + 多源 BFS 羽化回写；
## 水上格不回写(防填海)，桥格例外衔接；崖壁巷道保留台阶高差(台阶路语义)

## 道路相邻格最大高差（归一高；超过处形成台阶路）
@export_range(0.02, 0.3, 0.01) var road_max_grade := 0.1
## 切台/广场边缘的羽化宽度（格）
@export_range(0, 6, 1) var terrace_blend := 3


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_conform_step(self, ctx)
