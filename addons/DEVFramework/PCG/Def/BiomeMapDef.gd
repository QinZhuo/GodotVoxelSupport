@tool
class_name BiomeMapDef extends PCGGeneratorDef
## 生物群系图生成器 — 用多层噪声采样 高度/湿度/温度，映射到生物群系
##
## 每层噪声都是 NoiseLayerDef（包装 FastNoiseLite，可配置/可复现）。
## 生成结果写入管线 output[key]，值为 BiomeMap。

@export_range(8, 512, 1) var width := 96
@export_range(8, 512, 1) var height := 96

## 高度层（决定海洋/平原/山地）
@export var elevation_layer: NoiseLayerDef
## 湿度层（决定沙漠/草原/森林/沼泽）
@export var moisture_layer: NoiseLayerDef
## 温度层（决定寒带/温带/热带）
@export var temperature_layer: NoiseLayerDef
## 群系表（顺序即优先级，最后放兜底）
@export var biomes: Array[BiomeEntryDef] = []
## 群系过渡平滑次数（0=硬边界；越大边界越柔和、小斑块被吸收）
@export_range(0, 10, 1) var smoothing_passes := 0

func generate(ctx: PCGContext) -> void:
	var biome_map := PCGTool.generate_biome(self, ctx.rng)
	ctx.output[_effective_key()] = biome_map

func get_desc(_data) -> String:
	return "Biome %dx%d (%d 群系)" % [width, height, biomes.size()]

func _to_string() -> String:
	return name
