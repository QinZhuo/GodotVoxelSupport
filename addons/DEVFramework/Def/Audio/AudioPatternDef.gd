@tool
## 音符序列定义 — 显式排列一串音符，适合手工编写固定旋律/音效
class_name AudioPatternDef extends Def

## 使用的声部索引(指向 AudioSynthDef.voices 中第几项)
@export_range(0, 128, 1) var voice_index := 0
## 速度(拍/分钟)
@export_range(20.0, 400.0, 0.5) var bpm := 120.0
## 音符列表(顺序演奏; delay_beats 可留空/休止)
@export var notes: Array[AudioNoteDef] = []

## 每音符人性化随机(音分): 固定旋律也带"人手感"
@export_range(0, 200, 1) var pitch_jitter_cents := 0
## 每音符触发时间随机(毫秒)
@export_range(0, 200, 1) var timing_jitter_ms := 0
## 人性化随机种子(重掷可得到新变体)
@export var random_seed := 12345


## 每拍拍号（默认 4/4）
@export_range(1, 12, 1) var beats_per_bar := 4

func get_desc(_data) -> String:
	return "%d 音符 @%gBPM" % [notes.size(), bpm]

func _to_string() -> String:
	return "Pattern[%d, %gBPM]" % [notes.size(), bpm]
