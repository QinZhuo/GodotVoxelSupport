@tool
class_name LSystemDef extends PCGGeneratorDef
## L-System 生长生成器 — 用重写规则生成分形结构（线段集）
##
## 经典 turtle 图形 L-System：公理 → 迭代重写 → 按规则绘制线段。
## 输出 PackedVector2Array（每对点 = 一条线段），可做枝干/藤蔓/血管/闪电/道路。
## 生成结果写入管线 output[key]。seed 可复现（含角度抖动）。

## 初始公理（如 "F"、"A"）
@export var axiom := "F"
## 重写规则（字母 → 替换串），如 {"A": "F[+A][-A]"}
@export var rules: Dictionary = {}
## 迭代次数（越大结构越复杂，注意爆炸式增长）
@export_range(0, 8, 1) var iterations := 4
## 步长（每次 F 前进的距离，格/世界单位）
@export_range(0.5, 64.0, 0.5) var step_length := 8.0
## 转角（+/- 旋转角度，度）
@export_range(1, 180, 1) var angle_deg := 25.0
## 每层缩放（迭代子代步长 = 父步长 * factor，控制收敛）
@export_range(0.2, 1.0, 0.05) var length_factor := 0.7
## 每次 F 是否绘制线段（false 则仅移动，用于无痕定位）
@export var draw_on_f := true
## 起点
@export var origin := Vector2.ZERO
## 初始朝向角（度）
@export_range(0, 359, 1) var start_angle := -90.0
## 角度随机抖动（度，seed 可复现）
@export_range(0.0, 30.0, 0.5) var angle_jitter := 0.0

## 输出线段数上限保护（防止爆炸式增长卡死）
@export_range(100, 200000, 100) var max_segments := 20000


func generate(ctx: PCGContext) -> void:
	var segs := PCGTool.generate_lsystem(self, ctx.rng)
	ctx.output[_effective_key()] = segs


func get_desc(_data) -> String:
	return "L-System %d iter" % iterations

func _to_string() -> String:
	return name
