@tool
## 音频滤波器定义 — 状态变量滤波器(SVF)，可被包络/LFO 调制
class_name AudioFilterDef extends Def

enum Mode {
	## 低通(保留低频, 削弱高频)
	LOW_PASS,
	## 带通(只保留中间频段)
	BAND_PASS,
	## 高通(保留高频, 削弱低频)
	HIGH_PASS,
}

## 开关滤波器链
@export var enabled := false
## 滤波类型
@export var mode: Mode = Mode.LOW_PASS
@export_range(20.0, 20000.0, 1.0) var cutoff := 8000.0
@export_range(0.0, 1.0, 0.001) var resonance := 0.3
## 包络调制量(Hz)：正=随包络升高截止频率(经典开音效)，负=随包络降低
@export_range(-12000.0, 12000.0, 1.0) var cutoff_envelope_amount := 0.0
## LFO 调制量(Hz)，配合音色 vibrato_rate 使用
@export_range(-12000.0, 12000.0, 1.0) var cutoff_lfo_amount := 0.0

func get_desc(_data) -> String:
	if not enabled:
		return "Filter(off)"
	return "%s %.0fHz Q=%.2f" % [Mode.keys()[mode], cutoff, resonance]

func _to_string() -> String:
	return "%s(%.0fHz, r=%.2f)" % [Mode.keys()[mode], cutoff, resonance]
