@tool
## 音符定义 — 描述单个音符（音高/时长/力度/休止）
class_name AudioNoteDef extends Def

@export_range(0, 127, 1) var midi := 60
@export var is_rest := false
## 时长（拍）
@export_range(0.03125, 64.0, 0.03125) var length_beats := 1.0
@export_range(0.0, 1.0, 0.001) var velocity := 0.8
## 相对上一音符的延迟（拍），留空即顺序排列
@export_range(0.0, 64.0, 0.03125) var delay_beats := 0.0

func get_desc(_data) -> String:
	if is_rest:
		return "休止(%.3g拍)" % length_beats
	return "%s(%.3g拍, vel=%.2f)" % [AudioScaleDef._midi_name(midi), length_beats, velocity]

func _to_string() -> String:
	return "休止" if is_rest else "%s x%.3g" % [AudioScaleDef._midi_name(midi), length_beats]
