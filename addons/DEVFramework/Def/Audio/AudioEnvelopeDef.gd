@tool
## 音频 ADSR 包络定义 — 描述音符从按下到释放的音量曲线
class_name AudioEnvelopeDef extends Def

@export_range(0.0, 10.0, 0.001) var attack := 0.005
@export_range(0.0, 10.0, 0.001) var decay := 0.1
@export_range(0.0, 1.0, 0.001) var sustain := 0.7
@export_range(0.0, 10.0, 0.001) var release := 0.2
## 曲线指数度：0 为线性，>0 更早到达目标，<0 更晚到达
@export_range(-0.98, 0.98, 0.01) var curve := 0.0

func get_desc(_data) -> String:
	return "ADSR A%.3f/D%.3f/S%.2f/R%.3f" % [attack, decay, sustain, release]

func _to_string() -> String:
	return "ADSR(A=%.3f D=%.3f S=%.2f R=%.3f)" % [attack, decay, sustain, release]
