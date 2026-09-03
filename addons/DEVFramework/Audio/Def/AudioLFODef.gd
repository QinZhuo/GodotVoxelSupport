@tool
## 音频 LFO 定义 — 低频振荡器调制层，让音色随时间演化
## 一个声部可挂一个 LFO，同时调制多个目标：滤波截止(扫频)/音量(颤音律动)/声像/音高
## 经典用途：TB-303 滤波扫频、弦乐颤音、自动声像、律动抽吸
class_name AudioLFODef extends Def

## 总开关(关闭时全部调制不生效)
@export var enabled := false
## 调制波形(复用振荡器波形枚举; NOISE=随机采样保持)
@export var waveform: AudioOscillatorDef.Wave = AudioOscillatorDef.Wave.SINE
## LFO 频率(Hz): 0.1~1 慢扫, 4~10 颤音/抽吸, 20+ 接近音频调制
@export_range(0.01, 30.0, 0.01) var rate := 5.0
## 通用调制深度(0~1): 决定各目标调制强度
##   - 滤波: cutoff 在 ±depth 倍之间扫(1±depth)
##   - 音量: 在 1±depth 之间摆动(0.5 即可产生明显律动抽吸)
##   - 声像: pan 在 ±depth 之间摆动(自动声像)
##   - 音高: 在 ±depth 个半音之间摆动(颤音)
@export_range(0.0, 1.0, 0.01) var depth := 0.5

## 调制目标(可多选): 滤波截止频率(经典扫频音)
@export var mod_cutoff := false
## 调制目标: 音量(颤音/律动抽吸)
@export var mod_volume := false
## 调制目标: 声像(自动声像, 环绕感)
@export var mod_pan := false
## 调制目标: 音高(颤音/威诺, 单位半音)
@export var mod_pitch := false

func get_desc(_data) -> String:
	return "LFO %.2fHz %s d=%.2f%s%s%s%s" % [
		rate, AudioOscillatorDef.Wave.keys()[waveform], depth,
		" C" if mod_cutoff else "",
		" V" if mod_volume else "",
		" P" if mod_pan else "",
		" H" if mod_pitch else "",
	]

func _to_string() -> String:
	return "LFO(%.1fHz %s)" % [rate, AudioOscillatorDef.Wave.keys()[waveform]]
