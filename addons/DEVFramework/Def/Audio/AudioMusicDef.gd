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
	## 大九和弦(爵士色彩)
	MAJOR9,
	## 小九和弦(柔和爵士)
	MINOR9,
	## 属九和弦(蓝调爵士)
	DOMINANT9,
	## 大十一和弦(开阔爵士)
	MAJOR11,
	## 小十一和弦(现代爵士)
	MINOR11,
	## 属十一和弦(紧张爵士)
	DOMINANT11,
	## 大十三和弦(丰富爵士)
	MAJOR13,
	## 小十三和弦(深邃爵士)
	MINOR13,
	## 属十三和弦(饱满爵士)
	DOMINANT13,
	## 大七挂四和弦(空灵爵士)
	MAJOR7_SUS4,
	## 七挂二和弦(现代流行)
	SUS2_7,
	## 大和弦加九(流行/摇滚)
	MAJOR_ADD9,
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
## 段落结构: 空 = 整段用 bars+chord_progression(旧行为); 非空 = 按段展开(每段独立小节/和声/强度/启停/音区)
@export var sections: Array[AudioMusicSectionDef] = []
## 整体转调(半音, 正=升 负=降): 整条声部移调; 配合段落做副歌升调等
@export_range(-24, 24, 1) var transpose_semitones := 0
## 和弦色彩覆盖(调式交换/借用和弦): 音级 → ChordType, 如 {1: MAJOR7, 4: MINOR7, 5: DOMINANT9}
## 让某些小节的进行用不同和弦性质(近似平行调借用), 空 = 全用 chord_type
@export var chord_quality: Dictionary = {}
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
## 鼓节奏型(仅 DRUM 角色生效): 非空时用其行模式展开(支持切分/三连音/摇摆),
## 替代 drum_kit 的固定 4/4 节奏; 空则退回 drum_kit 固定节奏。可用 DrumPatternDef.preset("HOUSE") 等预设
@export var drum_pattern: DrumPatternDef = null

## 每音符音高随机(音分): MIDI 音高微抖动量, 常用 5~40, 消除机械感(鼓组/打击乐推荐)
@export_range(0, 200, 1) var pitch_jitter_cents := 0
## 每音符触发时间随机(毫秒): 制造 ~靠近/提前的瑕疵节奏, 打击乐更自然
@export_range(0, 200, 1) var timing_jitter_ms := 0

func get_desc(_data) -> String:
	return "%s %d小节@%dBPM" % [Role.keys()[role], bars, int(bpm)]

func _to_string() -> String:
	return "%s[%dg]@%.0fBPM" % [Role.keys()[role], bars, bpm]

## ======== 常用和声进行预设(返回音级数组, 1 起) ========

static func preset_progression(name: String) -> PackedInt32Array:
	match name.to_upper():
		"I_V_vi_IV", "POP":
			return PackedInt32Array([1, 5, 6, 4])
		"DOO_WOP", "50S":
			return PackedInt32Array([1, 6, 4, 5])
		"VI_IV_I_V", "POP_ANIME":
			return PackedInt32Array([6, 4, 1, 5])
		"ROYAL_ROAD", "JAPANESE":
			return PackedInt32Array([4, 3, 6, 1])
		"II_V_I", "JAZZ_BASIC":
			return PackedInt32Array([2, 5, 1])
		"JAZZ_TURNAROUND":
			return PackedInt32Array([1, 6, 2, 5])
		"II_V_I_VI":
			return PackedInt32Array([2, 5, 1, 6])
		"AEOLIAN":
			return PackedInt32Array([6, 3, 4, 1])
		"12_BAR_BLUES":
			return PackedInt32Array([1, 1, 1, 1, 4, 4, 1, 1, 5, 4, 1, 5])
		"CANON":
			return PackedInt32Array([1, 5, 6, 3, 4, 1, 4, 5])
	return PackedInt32Array([1, 5, 6, 4])

## 列出全部进行预设名
static func list_progressions() -> Array:
	return ["I_V_vi_IV", "DOO_WOP", "VI_IV_I_V", "ROYAL_ROAD", "II_V_I", "JAZZ_TURNAROUND",
		"II_V_I_VI", "AEOLIAN", "12_BAR_BLUES", "CANON"]
