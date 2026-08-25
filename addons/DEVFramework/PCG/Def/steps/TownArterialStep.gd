@tool
class_name TownArterialStep extends TownStepDef
## S2b 横穿主干道(Arterial) — 现代城区车行骨架
##
## 业内参照 Cities: Skylines 路网分级(Highway→Arterial→Collector→Local)：
## 先铺 1~3 条横穿全图的宽阔平直主干道(一横一纵即成十字骨架)，
## 再沿干道两侧按间距生长集散次街(Collector)，形成大街区城区肌理。
## 路面梯度由尾部 ConformStep 统一整平，遇水自动架桥。

@export_range(0, 3, 1) var arterial_h_count := 1
@export_range(0, 3, 1) var arterial_v_count := 1
@export_range(2, 5, 1) var arterial_width := 3
@export_range(0.0, 1.5, 0.05) var arterial_jitter := 0.25
@export_range(6, 32, 1) var arterial_collector_spacing := 12


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_arterial_step(self, ctx)
