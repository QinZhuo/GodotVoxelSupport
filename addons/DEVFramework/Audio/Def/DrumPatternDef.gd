@tool
## 鼓节奏型定义 — 用"行模式"描述鼓点(每字符一步), 支持任意步数/切分/三连音/深度摇摆
##
## 行内字符语义:
##   K=底鼓  S=军鼓  H=闭镲  h=开镲  T=通鼓  C=拍手  x=闭镲弱音  .=空
## 例如 16 步摇滚(每小节 4/4):
##   rows = {
##     "KICK":       "K...K...K...K...",
##     "SNARE":      "....S....S......",
##     "HAT_CLOSED": ".x.x.x.x.x.x.x.x",
##   }
##
## 预设: 静态预设函数生成常见风格(HOUSE/ROCK/TRAP/BREAKBEAT/FUNK/TECHNO/REGGAE/BALLAD),
## 也可直接配 .tres 资源自定义。AudioMusicDef.DRUM 角色配 drum_pattern 即启用(替代固定 4/4)。
class_name DrumPatternDef extends Def

## 每小节步数: 16=十六分音符, 12=八分三连音, 24=十六分三连音, 8=八分音符
@export_range(4, 48, 1) var steps := 16
## 摇摆深度(拍): 奇数步向后偏移, 制造律动(0=直线, 0.1~0.3 明显)
@export_range(0.0, 0.49, 0.01) var swing := 0.0
## 行模式表: 鼓槽名 → 行字符串(长度>=1, 循环采样; 常用 steps 长度)
@export var rows: Dictionary = {}

## 预设风格名(仅标识, 便于 Inspoector 区分; 实际节奏由 rows 决定)
@export var style := "custom"

func get_desc(_data) -> String:
	return "%s %d步 swing=%.2f rows=%d" % [style, steps, swing, rows.size()]

func _to_string() -> String:
	return "Drum[%s %dg]" % [style, steps]

## ======== 风格预设(静态生成, 可再手动微调后存成 .tres) ========

static func preset(name: String) -> DrumPatternDef:
	match name.to_upper():
		"ROCK":
			# 经典摇滚: 底鼓 0/2, 军鼓 1/3, 八分闭镲
			return _p(name, 16, 0.0, {
				"KICK": "K...K...K...K...",
				"SNARE": "....S....S......",
				"HAT_CLOSED": ".x.x.x.x.x.x.x.x",
			})
		"HOUSE":
			# 四踩底鼓 + 2/4 军鼓 + 反拍镲, 典型 120+ BPM 舞曲
			return _p(name, 16, 0.0, {
				"KICK": "K...K...K...K...",
				"SNARE": "....S....S......",
				"HAT_CLOSED": "..x..x..x..x..x.",
				"HAT_OPEN": "..........h.....",
			})
		"TRAP":
			# 重低音 + 三连点缀 + 密集镲, 半速陷阱律动
			return _p(name, 16, 0.15, {
				"KICK": "K......K....K...",
				"SNARE": "....S.......S...",
				"HAT_CLOSED": "xx.xx.xx.xx.xx.x",
				"HAT_OPEN": "h...h...h...h...",
			})
		"BREAKBEAT":
			# 切分军鼓 + 16 分镲, 碎拍(breakbeat)风格
			return _p(name, 16, 0.1, {
				"KICK": "K..K..K...K..K..",
				"SNARE": "....S....S.S..S.",
				"HAT_CLOSED": "xxxxxxxxxxxxxxxx",
			})
		"FUNK":
			# 切分贝斯律动, 军鼓偏移重音
			return _p(name, 16, 0.2, {
				"KICK": "K..K....K..K....",
				"SNARE": "..S..S..S..S..S.",
				"HAT_CLOSED": "x.x.x.x.x.x.x.x.",
			})
		"TECHNO":
			# 四踩 + 16 分镲无军鼓, 冰冷机械感
			return _p(name, 16, 0.0, {
				"KICK": "K...K...K...K...",
				"HAT_CLOSED": "xxxxxxxxxxxxxxxx",
			})
		"REGGAE":
			# 反拍军鼓(3 拍) + 弱底鼓, 雷鬼摇摆
			return _p(name, 16, 0.25, {
				"KICK": "K.......K.......",
				"SNARE": "..S...S...S...S.",
				"HAT_CLOSED": "....x....x....x.",
			})
		"BALLAD":
			# 慢速抒情: 稀疏底鼓/军鼓 + 开镲点缀
			return _p(name, 16, 0.0, {
				"KICK": "K.......K.......",
				"SNARE": "....S.......S...",
				"HAT_CLOSED": "..x.....x.......",
				"HAT_OPEN": "..........h.....",
			})
	return null

static func _p(style: String, steps: int, swing: float, rows: Dictionary) -> DrumPatternDef:
	var d := DrumPatternDef.new()
	d.style = style
	d.steps = steps
	d.swing = swing
	d.rows = rows
	return d

## 列出全部预设风格名
static func list_presets() -> Array:
	return ["ROCK", "HOUSE", "TRAP", "BREAKBEAT", "FUNK", "TECHNO", "REGGAE", "BALLAD"]
