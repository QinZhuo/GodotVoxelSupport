@tool
## 机位过渡规则: 为「从某机位切到某机位」指定专属过渡, 集中配置在 Brain 上。
class_name CameraBlendDef extends Resource

## 起点机位名(空 = 任意)
@export var from: StringName = &""
## 终点机位名(空 = 任意)
@export var to: StringName = &""
## 过渡时长(秒); < 0 = 沿用机位自身/Brain 默认
@export_range(-1, 10, 0.05, "or_greater") var time: float = -1.0
## 过渡曲线
@export var trans: Tween.TransitionType = Tween.TRANS_CUBIC
## 缓动方式
@export var ease: Tween.EaseType = Tween.EASE_IN_OUT
## 位置混合轨迹(枚举归属 [CameraTool])
@export var style: CameraTool.BlendStyle = CameraTool.BlendStyle.SPHERICAL


## 与本次切换的匹配度: -1 不命中, 数值越大越精确(含义见类注释的优先级表)
func match_score(from_name: StringName, to_name: StringName) -> int:
	if from != &"" and from != from_name:
		return -1
	if to != &"" and to != to_name:
		return -1
	if from != &"" and to != &"":
		return 3
	if from != &"":
		return 2
	if to != &"":
		return 1
	return 0
