@tool
## 机位过渡规则: 为「从某机位切到某机位」指定专属过渡, 集中配置在 Brain 上。
##
## from / to 按机位节点名匹配, 留空表示通配任意机位。多条规则都命中时, 精确者胜:
## [br]1. from 与 to 都指定且都命中
## [br]2. 仅 from 指定且命中(从该机位切出)
## [br]3. 仅 to 指定且命中(切入该机位)
## [br]4. from 与 to 都为空(全局统一)
## 都不命中时, 回退到目标机位自身的 blend_* 配置, 再退回 Brain 的 default_blend_time。
##
## time < 0 表示时长沿用回退链, 其余三项(trans/ease/style)命中即整体覆盖。
##
## [codeblock]
## # 例: 一切入过场机位都走 0.2 秒的利落切换
## var rule := CameraBlendDef.new()
## rule.to = &"Cinematic"
## rule.time = 0.2
## brain.blends.append(rule)
## [/codeblock]
##
## 用机位[b]名[/b]而非节点引用匹配: 规则是资源, 名字配置无引用失效问题, 且跨场景可复用。
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
