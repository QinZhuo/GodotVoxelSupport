@tool
## 自动编曲定义 — 根据音阶/和弦进行/角色生成一片音乐（主旋律、和弦、琶音、低音、鼓、铺底等）
class_name AudioMusicDef extends Def

enum Role {
	## 主旋律(级进随机游走, 自动落在音阶内)
	MELODY,
	## 和弦(整小节持续)
	CHORD,
	## 琶音(快速分解和弦)
	ARPEGGIO,
	## 低音(根音, 通常低八度)
	BASS,
	## 铺底(同和弦, 超长音)
	PAD,
	## 鼓组(4/4, 按 drum_kit 分轨)
	DRUM,
}
enum ChordType {
	## 大三和弦(明亮)
	MAJOR_TRIAD,
	## 小三和弦(暗淡/悲伤)
	MINOR_TRIAD,
	## 减三和弦(紧张)
	DIMINISHED,
	## 增三和弦(悬疑)
	AUGMENTED,
	## 挂二和弦(梦幻)
	SUS2,
	## 挂四和弦(开阔)
	SUS4,
	## 大七和弦(爵士/浪漫)
	MAJOR7,
	## 小七和弦(蓝调/流行)
	MINOR7,
	## 属七和弦(强烈倾向解决)
	DOMINANT7,
}
enum DrumKit {
	## 全套(底鼓+军鼓+闭镲)
	FULL,
	## 仅底鼓
	KICK,
	## 仅军鼓
	SNARE,
	## 仅闭镲(八分音符循环)
	HAT,
	## 开镲(单独点缀)
	HAT_OPEN,
}

## 使用的声部索引(指向 AudioSynthDef.voices 中第几项)
@export_range(0, 128, 1) var voice_index := 0
## 本片段扮演的角色(决定生成算法)
@export var role: Role = Role.MELODY
## 音阶/调式定义(根音+调式, 旋律与和弦的取音范围)
@export var scale: AudioScaleDef = AudioScaleDef.new()
## 速度(拍/分钟)
@export_range(30.0, 300.0, 0.5) var bpm := 120.0
## 生成的小节数（配合长片段即循环段）
@export_range(1, 64, 1) var bars := 4
## 和弦进行（音级，1 起），如 1 5 6 4
@export var chord_progression := PackedInt32Array([1, 5, 6, 4])
## 和弦类型(和弦/琶音/铺底角色的和声色彩)
@export var chord_type: ChordType = ChordType.MAJOR_TRIAD
## 相对根音的八度偏移
@export_range(-3, 3, 1) var octave := 0
## 音符间隔长度(拍)：MELODY/ARPEGGIO 用
@export_range(0.0625, 4.0, 0.0625) var note_length := 0.5
## 音符实际发声占比(gate)，0~1：小=跳跃短促(短音)，大=连贯(连音)
@export_range(0.05, 1.0, 0.01) var gate := 0.8
## 整体力度(0~1)
@export_range(0.0, 1.0, 0.001) var velocity := 0.8
## 摇摆/三连感偏移(拍)
@export_range(0.0, 0.49, 0.01) var swing := 0.0
## 随机种子: 同一种子永远生成同一旋律(变体请改种子)
@export_range(0, 999999999, 1) var random_seed := 12345
## 鼓组选择（仅 DRUM 角色生效）：整组 / 底鼓 / 军鼓 / 闭镲 / 开镲，便于分轨分配不同音色
@export var drum_kit: DrumKit = DrumKit.FULL

## 每音符音高随机(音分): MIDI 音高微抖动量, 常用 5~40, 消除机械感(鼓组/打击乐推荐)
@export_range(0, 200, 1) var pitch_jitter_cents := 0
## 每音符触发时间随机(毫秒): 制造 ~靠近/提前的瑕疵节奏, 打击乐更自然
@export_range(0, 200, 1) var timing_jitter_ms := 0

func get_desc(_data) -> String:
	return "%s %d小节@%dBPM" % [Role.keys()[role], bars, int(bpm)]

func _to_string() -> String:
	return "%s[%dg]@%.0fBPM" % [Role.keys()[role], bars, bpm]
