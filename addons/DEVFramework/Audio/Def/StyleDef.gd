@tool
## 风格模板定义 — 一键组合音色/编曲/鼓/和声/效果, 生成完整 AudioSynthDef
## 策划友好: 只配一个 StyleDef 资源(或 style= 预设名), build() 即可得到可播放的 BGM Def
## 声部条目(Dictionary): {role, preset, velocity, octave, note_length, intensity, enabled}
##   role:    AudioMusicDef.Role 枚举值(0=MELODY,1=CHORD,2=ARPEGGIO,3=BASS,4=PAD,5=DRUM)
##   preset:  音色模板名(voice_template, 如 "lead_square"/"bass_acid"/"drum_kick")
class_name StyleDef extends Def

## 风格名(内置预设见 list_presets; 空=自定义)
@export var style := "custom"

## ——— 全局 ———
@export var category: AudioSynthDef.Category = AudioSynthDef.Category.BGM
@export_range(8000, 48000, 1000) var sample_rate := 22050
@export_range(30.0, 300.0, 0.5) var bpm := 120.0
@export_range(0.0, 1.0, 0.01) var master_volume := 0.85
@export_range(0.0, 2.0, 0.05) var soft_clip := 0.6
@export var loop := true
@export var bus := "BGM"
## 效果链预设名(AudioTool.create_fx 支持): 如 ["compressor","delay"]
@export var fx: Array[String] = ["compressor"]

## ——— 调性/和声 ———
@export_range(0, 127, 1) var scale_root_midi := 60
@export var scale_type: AudioScaleDef.ScaleType = AudioScaleDef.ScaleType.MAJOR
@export var chord_progression := PackedInt32Array([1, 5, 6, 4])
@export var chord_type: AudioMusicDef.ChordType = AudioMusicDef.ChordType.MAJOR_TRIAD
## 调式交换: 音级 → ChordType(见 AudioMusicDef)
@export var chord_quality: Dictionary = {}
## 鼓模式预设名(DrumPatternDef.preset): 空=自动选择与风格匹配的鼓型
@export var drum_pattern_name := ""

## ——— 声部(角色+音色模板) ———
## 每项: {role:int, preset:String, velocity:float=0.8, octave:int=0, note_length:float=0.5, intensity:float=1.0, enabled:bool=true}
@export var voices: Array[Dictionary] = []

## ——— 段落(可选, 空=整段) ———
## 每项: {bars:int=4, intensity:float=1.0, enabled:bool=true, transpose:int=0}
@export var sections: Array[Dictionary] = []

func get_desc(_data) -> String:
	return "%s %d声部@%dBPM" % [style, voices.size(), int(bpm)]

func _to_string() -> String:
	return "Style[%s %dv]" % [style, voices.size()]

## ======== 构建 ========

## 把风格配方构建成完整 AudioSynthDef(可直接播放/烘焙)
func build() -> AudioSynthDef:
	var def := AudioSynthDef.new()
	def.category = category
	def.sample_rate = sample_rate
	def.master_volume = master_volume
	def.soft_clip = soft_clip
	def.loop = loop
	def.bus = bus
	def.fx_chain = AudioTool.fxs_from_names(fx)

	var scale := AudioScaleDef.new()
	scale.root_midi = scale_root_midi
	scale.scale_type = scale_type

	# 1) 音色: 先建声部表, DRUM 模板 → drum kit 记录
	var kit_by_voice := {}  # voice_index → DrumKit
	for v in voices:
		var preset := str(v.get("preset", ""))
		var vd := voice_template(preset)
		if vd == null:
			push_warning("StyleDef.build: 未知音色模板 '%s'" % preset)
			continue
		var kind: int = v.get("role", 0)
		if kind == AudioMusicDef.Role.DRUM:
			vd = _drum_template(preset, vd)
			var kit := _drum_kit_for(preset)
			kit_by_voice[def.voices.size()] = kit
		def.voices.append(vd)

	# 2) 编曲: 每个声部一个 AudioMusicDef
	var secs: Array = []
	if not sections.is_empty():
		for s in sections:
			var sd := AudioMusicSectionDef.new()
			sd.bars = int(s.get("bars", 4))
			sd.intensity = float(s.get("intensity", 1.0))
			sd.enabled = bool(s.get("enabled", true))
			sd.transpose_semitones = int(s.get("transpose", 0))
			secs.append(sd)

	var drum_pat: DrumPatternDef = null
	if not drum_pattern_name.is_empty():
		drum_pat = DrumPatternDef.preset(drum_pattern_name)

	for i in def.voices.size():
		var v: Dictionary = voices[i]
		var role: int = v.get("role", 0)
		var m := AudioMusicDef.new()
		m.role = role
		m.scale = scale
		m.bpm = bpm
		m.velocity = clampf(float(v.get("velocity", 0.8)), 0.0, 2.0)
		m.octave = int(v.get("octave", 0))
		m.note_length = float(v.get("note_length", 0.5))
		m.voice_index = i
		m.chord_progression = chord_progression
		if role != AudioMusicDef.Role.DRUM:
			m.chord_type = chord_type
			m.chord_quality = chord_quality
		if role == AudioMusicDef.Role.DRUM:
			m.drum_kit = kit_by_voice.get(i, AudioMusicDef.DrumKit.FULL)
			if drum_pat:
				m.drum_pattern = drum_pat
		if not secs.is_empty():
			m.sections.assign(secs.map(func(x): return x.duplicate()))
		if not bool(v.get("enabled", true)):
			continue
		def.music.append(m)
	return def

## ======== 音色模板库 ========

## 按名称返回音色模板(AudioVoiceDef)。DRUM 模板返回 drum 参数, 音乐模板返回振荡器/包络/滤波/LFO
static func voice_template(name: String) -> AudioVoiceDef:
	match name:
		"lead_square":
			return _tone([_o(AudioTool.Wave.SQUARE, 0.7, 0.0, 1)], 0.005, 0.1, 0.0, 0.08, 0.6)
		"lead_fm":
			return _tone([_o(AudioTool.Wave.SINE, 0.7, 0.0, 0, 0.5, 3.0, 9.0)], 0.01, 0.2, 0.0, 0.2, 0.5)
		"lead_triangle":
			return _tone([_o(AudioTool.Wave.TRIANGLE, 0.8)], 0.1, 0.3, 0.6, 0.4, 0.5)
		"pad_sine":
			return _tone([_o(AudioTool.Wave.SINE, 0.6)], 0.4, 0.6, 0.8, 0.6, 0.4)
		"pad_saw":
			return _tone([_o(AudioTool.Wave.SAW, 0.5, -8.0), _o(AudioTool.Wave.SAW, 0.5, 8.0), _o(AudioTool.Wave.TRIANGLE, 0.6)], 1.0, 1.5, 0.9, 1.5, 0.6)
		"pad_fm":
			return _tone([_o(AudioTool.Wave.SINE, 0.6, 0.0, 0, 0.5, 2.0, 7.0)], 0.4, 0.6, 0.8, 0.6, 0.4)
		"bass_saw":
			return _tone([_o(AudioTool.Wave.SAW, 0.7)], 0.01, 0.25, 0.5, 0.2, 0.8)
		"bass_square":
			return _tone([_o(AudioTool.Wave.SQUARE, 0.8, 0.0, -1)], 0.002, 0.3, 0.0, 0.15, 0.9)
		"bass_sub":
			return _tone([_o(AudioTool.Wave.SINE, 0.9)], 0.01, 0.3, 0.0, 0.2, 0.9)
		"bass_acid":
			var v := _tone([_o(AudioTool.Wave.SAW, 0.8)], 0.005, 0.3, 0.4, 0.2, 0.8)
			v.filter.enabled = true
			v.filter.mode = AudioFilterDef.Mode.LOW_PASS
			v.filter.cutoff = 500.0
			v.filter.resonance = 0.6
			v.lfo.enabled = true
			v.lfo.rate = 6.0
			v.lfo.depth = 0.7
			v.lfo.mod_cutoff = true
			return v
		"pluck":
			return _tone([_o(AudioTool.Wave.KARPLUS, 0.8), _o(AudioTool.Wave.KARPLUS, 0.3, 8.0, 1)], 0.001, 0.4, 0.0, 0.3, 0.7)
		"arp_triangle":
			return _tone([_o(AudioTool.Wave.TRIANGLE, 0.8)], 0.002, 0.15, 0.0, 0.1, 0.5)
		"drum_kick":
			return _drum(AudioVoiceDef.DrumType.KICK, 88.0, 0.2, 0.8, 0.95)
		"drum_snare":
			return _drum(AudioVoiceDef.DrumType.SNARE, 200.0, 0.55, 0.5, 0.7)
		"drum_hat":
			return _drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.5, 0.5, 0.35)
		"drum_open":
			return _drum(AudioVoiceDef.DrumType.HAT_OPEN, 0.0, 0.5, 0.5, 0.35)
		"drum_tom":
			return _drum(AudioVoiceDef.DrumType.TOM, 90.0, 0.3, 0.8, 0.9)
	return null

## DRUM 模板补全(kind 设为 DRUM)
static func _drum_template(preset: String, vd: AudioVoiceDef) -> AudioVoiceDef:
	vd.kind = AudioVoiceDef.Kind.DRUM
	return vd

## 音色模板名 → 鼓分轨(DRUM 角色的 drum_kit)
static func _drum_kit_for(preset: String) -> int:
	match preset:
		"drum_kick": return AudioMusicDef.DrumKit.KICK
		"drum_snare": return AudioMusicDef.DrumKit.SNARE
		"drum_hat": return AudioMusicDef.DrumKit.HAT
		"drum_open": return AudioMusicDef.DrumKit.HAT_OPEN
		"drum_tom": return AudioMusicDef.DrumKit.FULL
	return AudioMusicDef.DrumKit.FULL

static func _tone(oscs: Array, a: float, d: float, sus: float, r: float, vol: float) -> AudioVoiceDef:
	var v := AudioVoiceDef.new()
	v.kind = AudioVoiceDef.Kind.TONE
	v.oscillators.assign(oscs)
	v.envelope.attack = a
	v.envelope.decay = d
	v.envelope.sustain = sus
	v.envelope.release = r
	v.volume = vol
	return v

static func _o(wave: int, level := 1.0, detune := 0.0, oct := 0, pw := 0.5, fm_ratio := 1.0, fm_index := 0.0) -> AudioOscillatorDef:
	var o := AudioOscillatorDef.new()
	o.waveform = wave
	o.level = level
	o.detune_cents = detune
	o.octave_shift = oct
	o.pulse_width = pw
	o.fm_ratio = fm_ratio
	o.fm_index = fm_index
	return o

static func _drum(t: int, freq := 90.0, noise := 0.4, tone := 0.6, vol := 0.8) -> AudioVoiceDef:
	var v := AudioVoiceDef.new()
	v.kind = AudioVoiceDef.Kind.DRUM
	v.drum_type = t
	v.drum_freq = freq
	v.drum_noise = noise
	v.drum_tone = tone
	v.volume = vol
	return v

## ======== 内置风格预设 ========

static func preset(name: String) -> StyleDef:
	var s := StyleDef.new()
	match name.to_upper():
		"CHIPTUNE":
			s.style = "CHIPTUNE"
			s.bpm = 140.0
			s.scale_root_midi = 60
			s.scale_type = AudioScaleDef.ScaleType.MAJOR
			s.fx = ["compressor"]
			s.drum_pattern_name = "TECHNO"
			s.voices = [
				{"role": AudioMusicDef.Role.MELODY, "preset": "lead_square", "note_length": 0.25, "velocity": 0.9},
				{"role": AudioMusicDef.Role.BASS, "preset": "bass_square", "velocity": 0.85},
				{"role": AudioMusicDef.Role.ARPEGGIO, "preset": "arp_triangle", "note_length": 0.125, "velocity": 0.5},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_hat"},
			]
		"ROCK":
			s.style = "ROCK"
			s.bpm = 130.0
			s.soft_clip = 0.8
			s.scale_root_midi = 57
			s.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MINOR
			s.chord_type = AudioMusicDef.ChordType.SUS2
			s.fx = ["distortion", "compressor"]
			s.drum_pattern_name = "ROCK"
			s.voices = [
				{"role": AudioMusicDef.Role.CHORD, "preset": "lead_square", "velocity": 0.7},
				{"role": AudioMusicDef.Role.BASS, "preset": "bass_square", "velocity": 0.9},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_kick"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_snare"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_hat"},
			]
		"HOUSE":
			s.style = "HOUSE"
			s.bpm = 124.0
			s.scale_root_midi = 57
			s.scale_type = AudioScaleDef.ScaleType.DORIAN
			s.fx = ["compressor", "delay"]
			s.drum_pattern_name = "HOUSE"
			s.voices = [
				{"role": AudioMusicDef.Role.CHORD, "preset": "pad_fm", "velocity": 0.5},
				{"role": AudioMusicDef.Role.BASS, "preset": "bass_saw", "velocity": 0.8},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_kick"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_snare"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_hat"},
			]
		"JAZZ":
			s.style = "JAZZ"
			s.bpm = 120.0
			s.scale_root_midi = 60
			s.scale_type = AudioScaleDef.ScaleType.MAJOR
			s.chord_progression = PackedInt32Array([2, 5, 1, 6])
			s.chord_type = AudioMusicDef.ChordType.MINOR7
			s.chord_quality = {5: AudioMusicDef.ChordType.DOMINANT9, 1: AudioMusicDef.ChordType.MAJOR9, 2: AudioMusicDef.ChordType.MINOR7, 6: AudioMusicDef.ChordType.MINOR7}
			s.fx = ["compressor", "reverb"]
			s.drum_pattern_name = ""
			s.voices = [
				{"role": AudioMusicDef.Role.CHORD, "preset": "pad_fm", "velocity": 0.5},
				{"role": AudioMusicDef.Role.BASS, "preset": "bass_saw", "velocity": 0.8},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_kick"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_snare"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_hat"},
			]
		"TRAP":
			s.style = "TRAP"
			s.bpm = 140.0
			s.soft_clip = 0.7
			s.scale_root_midi = 50
			s.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MINOR
			s.fx = ["compressor", "delay"]
			s.drum_pattern_name = "TRAP"
			s.voices = [
				{"role": AudioMusicDef.Role.BASS, "preset": "bass_sub", "velocity": 0.9},
				{"role": AudioMusicDef.Role.MELODY, "preset": "lead_fm", "note_length": 0.5, "velocity": 0.7},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_kick"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_snare"},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_hat"},
			]
		"CINEMATIC":
			s.style = "CINEMATIC"
			s.bpm = 70.0
			s.scale_root_midi = 55
			s.scale_type = AudioScaleDef.ScaleType.DORIAN
			s.chord_type = AudioMusicDef.ChordType.MAJOR7
			s.chord_quality = {6: AudioMusicDef.ChordType.MINOR7, 5: AudioMusicDef.ChordType.DOMINANT7}
			s.fx = ["reverb_hall", "compressor"]
			s.drum_pattern_name = "BALLAD"
			s.voices = [
				{"role": AudioMusicDef.Role.PAD, "preset": "pad_saw", "velocity": 0.6},
				{"role": AudioMusicDef.Role.BASS, "preset": "bass_sub", "velocity": 0.7, "octave": -1},
				{"role": AudioMusicDef.Role.DRUM, "preset": "drum_tom"},
			]
		"WORLD":
			s.style = "WORLD"
			s.bpm = 90.0
			s.scale_root_midi = 60
			s.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MAJOR
			s.fx = ["reverb", "delay"]
			s.voices = [
				{"role": AudioMusicDef.Role.ARPEGGIO, "preset": "pluck", "note_length": 0.25, "velocity": 0.7},
				{"role": AudioMusicDef.Role.MELODY, "preset": "lead_triangle", "note_length": 0.5, "velocity": 0.7},
			]
		"AMBIENT":
			s.style = "AMBIENT"
			s.bpm = 60.0
			s.soft_clip = 0.4
			s.scale_root_midi = 57
			s.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MINOR
			s.fx = ["reverb_hall", "delay"]
			s.voices = [
				{"role": AudioMusicDef.Role.PAD, "preset": "pad_sine", "velocity": 0.4},
				{"role": AudioMusicDef.Role.BASS, "preset": "bass_sub", "velocity": 0.6, "octave": -1},
				{"role": AudioMusicDef.Role.ARPEGGIO, "preset": "lead_triangle", "note_length": 0.25, "velocity": 0.5},
			]
	return s

## 列出全部内置风格
static func list_presets() -> Array:
	return ["CHIPTUNE", "ROCK", "HOUSE", "JAZZ", "TRAP", "CINEMATIC", "WORLD", "AMBIENT"]
