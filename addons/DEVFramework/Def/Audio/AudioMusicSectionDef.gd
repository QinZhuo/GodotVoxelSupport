@tool
## 音乐段落定义 — 让一条 AudioMusicDef 展开成多段落结构(intro/verse/chorus/bridge)
## 每个段落独立控制：小节数、和弦进行、强度、乐器启停、音区偏移
## 空段落列表 = 旧行为(整段用 AudioMusicDef.bars + chord_progression)
class_name AudioMusicSectionDef extends Def

## 本段小节数(段与段无缝拼接, 总长 = 各段 bars 之和)
@export_range(1, 64, 1) var bars := 4
## 本段和弦进行(音级, 1 起); 留空则继承 AudioMusicDef.chord_progression
@export var chord_progression := PackedInt32Array()
## 本段强度(0~2): 缩放该声部 velocity, >1 增强 <1 减弱; 配合 enabled 做段落起伏
@export_range(0.0, 2.0, 0.01) var intensity := 1.0
## 本段该声部是否发声(乐器增减): 例如 intro 关鼓 / chorus 全开
@export var enabled := true
## 本段相对根音八度偏移(如副歌旋律高八度提升张力)
@export_range(-3, 3, 1) var octave_shift := 0
## 本段转调(半音): 叠加在 AudioMusicDef.transpose_semitones 之上, 用于段落间转调(如副歌升调)
@export_range(-24, 24, 1) var transpose_semitones := 0

func get_desc(_data) -> String:
	return "%d小节%sx%.2f" % [bars, " 开" if enabled else " 关", intensity]

func _to_string() -> String:
	return "Section[%dg %s x%.1f]" % [bars, "on" if enabled else "off", intensity]
