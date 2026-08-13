@tool
class_name NoiseLayerDef extends Def
## 噪声层定义 — 包装 Godot 内置 FastNoiseLite
##
## FastNoiseLite 本身就是 Resource，可在 Inspector 里直接配置
## （噪声类型 / 频率 / 分形 / 细胞噪声 / 种子等）。本类在其基础上叠加
## 归一化 / 反相 / 对比度 / 偏移 / 权重，便于组合出地形或群系。

## 底层噪声（Godot 内置 FastNoiseLite，直接在 Inspector 配置）
@export var noise: FastNoiseLite = FastNoiseLite.new()
## 输出对比度（>1 拉高对比，<1 压平）
@export_range(0.0, 4.0, 0.05) var contrast := 1.0
## 反相（1-x）
@export var invert := false
## 输出偏移（正偏移整体抬高）
@export var offset := 0.0
## 叠加权重
@export_range(0.0, 1.0, 0.01) var weight := 1.0

## 复制一份底层噪声并设置种子（不污染 Def 静态配置，保证可复现）
func build_noise(seed := 0) -> FastNoiseLite:
	var n: FastNoiseLite = noise.duplicate() as FastNoiseLite if noise else FastNoiseLite.new()
	if seed != 0:
		n.seed = seed
	return n

## 对已构建的噪声采样，输出 0..1
func sample(n: FastNoiseLite, x: float, y: float) -> float:
	var v := (n.get_noise_2d(x, y) + 1.0) * 0.5
	if invert:
		v = 1.0 - v
	v = clampf(v * contrast + offset, 0.0, 1.0) * weight
	return clampf(v, 0.0, 1.0)

## 3D 采样（体素地形用），输出 0..1
func sample_3d(n: FastNoiseLite, x: float, y: float, z: float) -> float:
	var v := (n.get_noise_3d(x, y, z) + 1.0) * 0.5
	if invert:
		v = 1.0 - v
	v = clampf(v * contrast + offset, 0.0, 1.0) * weight
	return clampf(v, 0.0, 1.0)

## 直接采样（内部自动构建噪声；大量采样请用 build_noise + sample 复用）
func get_value(x: float, y: float, seed := 0) -> float:
	return sample(build_noise(seed), x, y)

## 直接 3D 采样
func get_value_3d(x: float, y: float, z: float, seed := 0) -> float:
	return sample_3d(build_noise(seed), x, y, z)

## FastNoiseLite 原生枚举无法在类型上取 keys()，这里手动映射名称
const NOISE_TYPE_NAMES := ["SIMPLEX", "SIMPLEX_SMOOTH", "CELLULAR", "PERLIN", "VALUE_CUBIC", "VALUE"]

func get_desc(_data) -> String:
	var t := "?"
	if noise and noise.noise_type >= 0 and noise.noise_type < NOISE_TYPE_NAMES.size():
		t = NOISE_TYPE_NAMES[noise.noise_type]
	return "Noise[%s]" % [t]

func _to_string() -> String:
	return name
