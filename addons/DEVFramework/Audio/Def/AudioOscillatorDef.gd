@tool
## 音频振荡器定义 — 一个音色可由多个振荡器层叠加而成（含 PolyBLEP 抗锯齿）
class_name AudioOscillatorDef extends Def

enum Wave {
	## 正弦(纯净圆润)
	SINE,
	## 方波(明亮复古, 8-bit)
	SQUARE,
	## 锯齿(明亮有力)
	SAW,
	## 三角(柔和介于正弦与方波)
	TRIANGLE,
	## 脉冲(方波+占空比调制)
	PULSE,
	## 噪声(打击颗粒/风/爆炸)
	NOISE,
	## 拨弦(经典 Karplus-Strong 物理建模, 吉他/竖琴/古筝类衰减拨弦音色)
	KARPLUS,
}

## 波形: 决定音色基本质感
@export var waveform: Wave = Wave.SINE
## 该振荡器电平(0~1), 多振荡器叠加时的相对权重
@export_range(0.0, 1.0, 0.001) var level := 1.0
## 失谐（音分），正负均可，多个振荡器失谐可形成丰富音色
@export_range(-1200.0, 1200.0, 1.0) var detune_cents := 0.0
## 八度偏移(正负均可)
@export_range(-36, 36, 1) var octave_shift := 0
## PULSE 波形的占空比(0~0.95)
@export_range(0.01, 0.95, 0.01) var pulse_width := 0.5
## 相位偏移(0~1)，用于错开多个振荡器
@export_range(0.0, 1.0, 0.01) var phase_offset := 0.0

## ——— FM 频率调制(调制器-载波对, DX7 风格; fm_index>0 时启用) ———
## 调制器频率 = 载波频率 × ratio(1=同频, 2=八度, 3=五度+八度, 非整数=金属/钟类)
@export_range(0.1, 16.0, 0.01) var fm_ratio := 1.0
## 调制指数(0=关闭 FM; 越大谐波越丰富/越明亮, 电钢/钟/贝斯常用 2~8)
@export_range(0.0, 32.0, 0.05) var fm_index := 0.0

## ——— Karplus-Strong 拨弦参数(仅 waveform=KARPLUS 生效) ———
## 波表低通阻尼(0.5=经典, 越小衰减越快/音越闷, 越大泛音越丰富)
@export_range(0.05, 1.0, 0.001) var ks_damping := 0.5

func get_desc(_data) -> String:
	var w: String = Wave.keys()[waveform]
	return "%s x%.2f%s" % [w, level, ("+" + str(detune_cents) + "c") if detune_cents != 0.0 else ""]

func _to_string() -> String:
	return "%s(%.2f, detune=%dc)" % [Wave.keys()[waveform], level, int(detune_cents)]
