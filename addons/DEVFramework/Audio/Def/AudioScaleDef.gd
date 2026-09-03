@tool
## 音阶定义 — 描述调式与根音，供自动编曲生成音符使用
class_name AudioScaleDef extends Def

enum ScaleType {
	## 大调(明亮欢快, 默认)
	MAJOR,
	## 自然小调(忧伤)
	NATURAL_MINOR,
	## 和声小调(异域/紧张)
	HARMONIC_MINOR,
	## 旋律小调(柔和上行)
	MELODIC_MINOR,
	## 大调五声(中国风/轻快, 易哼唱)
	PENTATONIC_MAJOR,
	## 小调五声(流行/布鲁斯)
	PENTATONIC_MINOR,
	## 多利亚(调式二, 冒险/史诗)
	DORIAN,
	## 弗里吉亚(调式三, 黑暗/弗拉门戈)
	PHRYGIAN,
	## 利底亚(调式四, 空灵/梦幻)
	LYDIAN,
	## 混合利底亚(调式五, 摇滚/放克)
	MIXOLYDIAN,
	## 洛克利亚(调式七, 极暗/不安)
	LOCRIAN,
	## 全音阶(朦胧/科幻)
	WHOLE_TONE,
	## 半音阶(任意/实验)
	CHROMATIC,
}

## 根音(MIDI 音高, 60=C4)
@export_range(0, 127, 1) var root_midi := 60
## 调式(影响可用音符集合)
@export var scale_type: ScaleType = ScaleType.MAJOR

## 各调式的音程（以半音计）
static func get_intervals(type: ScaleType) -> PackedInt32Array:
	match type:
		ScaleType.MAJOR:
			return PackedInt32Array([0, 2, 4, 5, 7, 9, 11])
		ScaleType.NATURAL_MINOR:
			return PackedInt32Array([0, 2, 3, 5, 7, 8, 10])
		ScaleType.HARMONIC_MINOR:
			return PackedInt32Array([0, 2, 3, 5, 7, 8, 11])
		ScaleType.MELODIC_MINOR:
			return PackedInt32Array([0, 2, 3, 5, 7, 9, 11])
		ScaleType.PENTATONIC_MAJOR:
			return PackedInt32Array([0, 2, 4, 7, 9])
		ScaleType.PENTATONIC_MINOR:
			return PackedInt32Array([0, 3, 5, 7, 10])
		ScaleType.DORIAN:
			return PackedInt32Array([0, 2, 3, 5, 7, 9, 10])
		ScaleType.PHRYGIAN:
			return PackedInt32Array([0, 1, 3, 5, 7, 8, 10])
		ScaleType.LYDIAN:
			return PackedInt32Array([0, 2, 4, 6, 7, 9, 11])
		ScaleType.MIXOLYDIAN:
			return PackedInt32Array([0, 2, 4, 5, 7, 9, 10])
		ScaleType.LOCRIAN:
			return PackedInt32Array([0, 1, 3, 5, 6, 8, 10])
		ScaleType.WHOLE_TONE:
			return PackedInt32Array([0, 2, 4, 6, 8, 10])
		ScaleType.CHROMATIC:
			return PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
	return PackedInt32Array([0, 2, 4, 5, 7, 9, 11])

func get_desc(_data) -> String:
	var name := "%s(%s)" % [ScaleType.keys()[scale_type], _midi_name(root_midi)]
	return name

func _to_string() -> String:
	return "%s %s" % [_midi_name(root_midi), ScaleType.keys()[scale_type]]

## 音级(1 起) → MIDI 音高
func degree_to_midi(degree: int) -> int:
	var intervals := get_intervals(scale_type)
	var idx := (degree - 1) % intervals.size()
	var oct := (degree - 1) / intervals.size()
	return root_midi + intervals[idx] + 12 * oct

static func _midi_name(m: int) -> String:
	var names := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [names[m % 12], m / 12 - 1]
