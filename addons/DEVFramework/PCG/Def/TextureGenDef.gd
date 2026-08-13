@tool
class_name TextureGenDef extends PCGGeneratorDef
## 程序化纹理生成器 — 用噪声 + 色带生成可复现纹理（Image）
##
## 支持多种算法：噪声 / 云 / 木纹 / 砖墙 / 水面。
## 生成结果写入管线 output[key]，值为 Image（2D 纹理位图）。
## 全参数可配置资源 + seed 可复现。

enum Type {
	NOISE,    ## 噪声灰度/色带
	CLOUDS,   ## 云（分形噪声阈值 + 亮色带）
	WOOD,     ## 木纹（环形噪声条纹）
	BRICK,    ## 砖墙（网格 + 噪声扰动 + 灰浆缝）
	WATER,    ## 水面（低频噪声相位 + 波纹 + 深浅色带）
}

@export var type: Type = Type.NOISE
@export_range(16, 1024, 1) var width := 256
@export_range(16, 1024, 1) var height := 256
## 基础种子偏移（0 用生成 rng 的种子）
@export var seed_offset := 0

## 噪声层（各算法共用；频率/分形在 Inspector 配 FastNoiseLite）
@export var noise_layer: NoiseLayerDef
## 色带：0=值低端颜色，1=值高端颜色（按噪声值采样）
@export var gradient: Gradient = null

## NOISE/CLOUDS: 值阈值（> threshold 着高端色，否则低端色过渡）
@export_range(0.0, 1.0, 0.01) var threshold := 0.5
## WOOD: 木纹环密度（越大年轮越密）
@export_range(0.5, 20.0, 0.5) var ring_density := 4.0
## BRICK: 砖块宽高（格）
@export_range(2, 64, 1) var brick_width := 24
@export_range(2, 64, 1) var brick_height := 12
## BRICK: 灰浆缝厚度（格）
@export_range(1, 8, 1) var mortar_thickness := 2
## WATER: 波纹强度（叠加高频细节）
@export_range(0.0, 1.0, 0.05) var ripple_strength := 0.3

## 最终亮度对比度
@export_range(0.5, 2.0, 0.05) var contrast := 1.0


func generate(ctx: PCGContext) -> void:
	var img := PCGTool.generate_texture(self, ctx.rng)
	ctx.output[_effective_key()] = img


func get_desc(_data) -> String:
	return "Texture[%s]" % Type.keys()[type]

func _to_string() -> String:
	return name
