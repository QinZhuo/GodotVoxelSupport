@tool
## 示例音频定义生成器 — 一键生成基准音效(激光/爆炸/拾取/攻击)与循环 BGM，并渲染出 .tres/.wav
## 可通过编辑器菜单「DEV 音频 → 生成示例音频定义」调用，也可在脚本中直接 create_all()
class_name DevAudioExamples

const OUT_DIR := "res://Assets/Def/Audio/Examples/"

## 生成全部示例定义资源并渲染成可播放文件
static func create_all(save_tres := true, render_wav := true) -> Dictionary:
	var results := {}
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var all := _build_synths()
	for name in all.keys():
		var def: AudioSynthDef = all[name]
		var path: String = OUT_DIR + String(name) + ".tres"
		if save_tres:
			var err := ResourceSaver.save(def, path)
			if err != OK:
				LogTool.error("音频", "保存定义失败 ", name, " err=", err)
				results[name] = {"tres": err}
				continue
		if render_wav:
			var stream := AudioSynthTool.generate(def)
			if stream == null:
				LogTool.error("音频", "渲染失败: ", name)
				results[name] = {"tres": OK, "stream": ERR_BUG}
				continue
			var wav_err := AudioTool.save_wav(stream, OUT_DIR + name + ".wav")
			if wav_err != OK:
				LogTool.error("音频", "写 WAV 失败: ", name, " err=", wav_err)
			results[name] = {"tres": OK, "wav": wav_err, "seconds": stream.data.size() / (2.0 * 2.0 * stream.mix_rate)}
	return results

static func _build_synths() -> Dictionary:
	var d := {}
	d["SFX_Laser"] = _synth_laser()
	d["SFX_Explosion"] = _synth_explosion()
	d["SFX_Coin"] = _synth_coin()
	d["SFX_Hit"] = _synth_hit()
	d["BGM_Loop_Adventure"] = _synth_adventure()
	d["BGM_Loop_Ambient"] = _synth_ambient()
	d["SFX_Jump"] = _synth_jump()
	d["SFX_UI_Click"] = _synth_ui_click()
	d["SFX_Powerup"] = _synth_powerup()
	d["SFX_Steps"] = _synth_steps()
	d["SFX_Whoosh"] = _synth_whoosh()
	d["SFX_Magic"] = _synth_magic()
	d["SFX_Impact"] = _synth_impact()
	d["SFX_ElectricPiano"] = _synth_electric_piano()
	d["SFX_Pluck"] = _synth_pluck()
	d["SFX_AcidBass"] = _synth_acid()
	d["BGM_Loop_Sections"] = _synth_sections()
	d["BGM_Loop_House"] = _synth_house()
	d["BGM_Loop_Jazz"] = _synth_jazz()
	d["BGM_Showcase"] = _synth_showcase()
	d["BGM_Chiptune"] = _synth_chiptune()
	d["BGM_Rock"] = _synth_rock()
	d["BGM_Trap"] = _synth_trap()
	d["BGM_Cinematic"] = _synth_cinematic()
	d["BGM_World"] = _synth_world()
	return d

# —— 便捷构造 ——
static func _osc(wave: int, level := 1.0, detune := 0.0, oct := 0, pw := 0.5,
		fm_ratio := 1.0, fm_index := 0.0, ks_damping := 0.5) -> AudioOscillatorDef:
	var o := AudioOscillatorDef.new()
	o.waveform = wave
	o.level = level
	o.detune_cents = detune
	o.octave_shift = oct
	o.pulse_width = pw
	o.fm_ratio = fm_ratio
	o.fm_index = fm_index
	o.ks_damping = ks_damping
	return o

static func _env(a := 0.005, d := 0.1, s := 0.7, r := 0.2) -> AudioEnvelopeDef:
	var e := AudioEnvelopeDef.new()
	e.attack = a
	e.decay = d
	e.sustain = s
	e.release = r
	return e

static func _filt(mode: int, cut: float, res := 0.3, env_amt := 0.0) -> AudioFilterDef:
	var f := AudioFilterDef.new()
	f.enabled = true
	f.mode = mode
	f.cutoff = cut
	f.resonance = res
	f.cutoff_envelope_amount = env_amt
	return f

static func _note(midi: int, beats: float, vel := 0.8) -> AudioNoteDef:
	var n := AudioNoteDef.new()
	n.midi = midi
	n.length_beats = beats
	n.velocity = vel
	return n

static func _voice_tone(os: Array[AudioOscillatorDef], e: AudioEnvelopeDef, vol := 0.8, pan := 0.0) -> AudioVoiceDef:
	var v := AudioVoiceDef.new()
	v.kind = AudioVoiceDef.Kind.TONE
	v.oscillators = os
	v.envelope = e
	v.volume = vol
	v.pan = pan
	return v

static func _voice_drum(t: int, freq := 90.0, noise := 0.4, tone := 0.6, vol := 0.8) -> AudioVoiceDef:
	var v := AudioVoiceDef.new()
	v.kind = AudioVoiceDef.Kind.DRUM
	v.drum_type = t
	v.drum_freq = freq
	v.drum_noise = noise
	v.drum_tone = tone
	v.volume = vol
	return v

static func _synth_laser() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.95
	s.soft_clip = 0.6
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["limiter"])
	var v := _voice_tone(
		[_osc(AudioTool.Wave.SAW, 0.6), _osc(AudioTool.Wave.SQUARE, 0.3, 7.0, 0, 0.25)],
		_env(0.001, 0.12, 0.0, 0.04), 0.9)
	v.noise_amount = 0.15
	v.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 6000.0, 0.3, 3000.0)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 300.0
	p.voice_index = 0
	p.notes = [_note(96, 0.05), _note(88, 0.05), _note(79, 0.06), _note(72, 0.06), _note(60, 0.08)]
	s.patterns = [p]
	return s

static func _synth_explosion() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 1.0
	s.soft_clip = 1.2
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["reverb", "delay"])
	var v := _voice_tone([_osc(AudioTool.Wave.SINE, 0.7, 0.0, -1), _osc(AudioTool.Wave.SAW, 0.4)], _env(0.004, 0.55, 0.0, 0.35), 1.0)
	v.noise_amount = 0.9
	v.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 220.0, 0.2, 2600.0)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 120.0
	p.voice_index = 0
	p.notes = [_note(36, 0.8)]
	s.patterns = [p]
	return s

static func _synth_coin() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.85
	s.bus = "UI"
	var v := _voice_tone(
		[_osc(AudioTool.Wave.SINE, 0.8), _osc(AudioTool.Wave.SINE, 0.4, 4.0)],
		_env(0.002, 0.25, 0.1, 0.12), 0.9)
	v.filter = _filt(AudioFilterDef.Mode.HIGH_PASS, 1500.0)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 200.0
	p.voice_index = 0
	p.notes = [_note(88, 0.12), _note(88, 0.12), _note(91, 0.18)]
	s.patterns = [p]
	return s

static func _synth_hit() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.9
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["limiter"])
	var v := _voice_tone(
		[_osc(AudioTool.Wave.SQUARE, 0.6, 0.0, 0, 0.3), _osc(AudioTool.Wave.SAW, 0.4)],
		_env(0.001, 0.09, 0.0, 0.06), 1.0)
	v.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 1600.0, 0.4)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 240.0
	p.voice_index = 0
	p.notes = [_note(48, 0.05), _note(36, 0.08)]
	s.patterns = [p]
	return s

## 冒险主题循环 BGM：低音 + 和弦 + 主旋律 + 鼓组
static func _synth_adventure() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 44100
	s.loop = true
	s.master_volume = 0.85
	s.soft_clip = 0.5
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["compressor", "delay"])

	# 音色
	var bass := _voice_tone([_osc(AudioTool.Wave.SAW, 0.7)], _env(0.004, 0.3, 0.5, 0.15), 0.7)
	bass.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 340.0, 0.3)
	var pad := _voice_tone(
		[_osc(AudioTool.Wave.SINE, 0.6), _osc(AudioTool.Wave.SAW, 0.25)],
		_env(0.3, 0.4, 0.8, 0.4), 0.35, -0.4)
	pad.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 1400.0, 0.2)
	var lead := _voice_tone(
		[_osc(AudioTool.Wave.SQUARE, 0.55, 0.0, 1), _osc(AudioTool.Wave.SINE, 0.5)],
		_env(0.01, 0.12, 0.0, 0.14), 0.5, 0.3)
	lead.vibrato_rate = 5.5
	lead.vibrato_depth = 0.02
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 88.0, 0.2, 0.8, 0.95)
	var snare := _voice_drum(AudioVoiceDef.DrumType.SNARE, 200.0, 0.55, 0.5, 0.7)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.5, 0.5, 0.35)
	s.voices = [bass, pad, lead, kick, snare, hat]

	# 编曲（4 小节循环）
	var scale := AudioScaleDef.new()
	scale.root_midi = 60
	scale.scale_type = AudioScaleDef.ScaleType.DORIAN

	var mel := AudioMusicDef.new()
	mel.voice_index = 2
	mel.role = AudioMusicDef.Role.MELODY
	mel.scale = scale
	mel.bpm = 120.0
	mel.bars = 4
	mel.chord_progression = PackedInt32Array([1, 6, 4, 5])
	mel.note_length = 0.5
	mel.gate = 0.85
	mel.octave = 1
	mel.velocity = 0.9
	mel.random_seed = 20260701

	var chord := AudioMusicDef.new()
	chord.role = AudioMusicDef.Role.CHORD
	chord.scale = scale
	chord.bpm = 120.0
	chord.bars = 4
	chord.chord_progression = PackedInt32Array([1, 6, 4, 5])
	chord.gate = 0.95
	chord.velocity = 0.5
	chord.voice_index = 1

	var bassm := AudioMusicDef.new()
	bassm.role = AudioMusicDef.Role.BASS
	bassm.scale = scale
	bassm.bpm = 120.0
	bassm.bars = 4
	bassm.chord_progression = PackedInt32Array([1, 6, 4, 5])
	bassm.velocity = 0.85
	bassm.voice_index = 0

	var dk := AudioMusicDef.new()
	dk.role = AudioMusicDef.Role.DRUM
	dk.bars = 4
	dk.bpm = 120.0
	dk.drum_kit = AudioMusicDef.DrumKit.KICK
	dk.voice_index = 3

	var ds := AudioMusicDef.new()
	ds.role = AudioMusicDef.Role.DRUM
	ds.bars = 4
	ds.bpm = 120.0
	ds.drum_kit = AudioMusicDef.DrumKit.SNARE
	ds.voice_index = 4

	var dh := AudioMusicDef.new()
	dh.role = AudioMusicDef.Role.DRUM
	dh.bars = 4
	dh.bpm = 120.0
	dh.drum_kit = AudioMusicDef.DrumKit.HAT
	dh.voice_index = 5

	s.music = [bassm, chord, mel, dk, ds, dh]
	return s

## 环境氛围循环 BGM：弛缓铺底 + 低音 + 琶音，无鼓
static func _synth_ambient() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.AMBIENT
	s.sample_rate = 44100
	s.loop = true
	s.master_volume = 0.8
	s.soft_clip = 0.4
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["reverb_hall", "delay"])

	var pad := _voice_tone(
		[_osc(AudioTool.Wave.SINE, 0.5), _osc(AudioTool.Wave.SINE, 0.3, 3.0, 1)],
		_env(1.2, 1.0, 0.8, 1.5), 0.35, -0.5)
	pad.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 900.0, 0.15)
	var drone := _voice_tone([_osc(AudioTool.Wave.SAW, 0.5, 0.0, -1)], _env(2.0, 0.5, 0.9, 2.0), 0.6, 0.5)
	drone.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 300.0, 0.2)
	var arp := _voice_tone([_osc(AudioTool.Wave.SINE, 0.7)], _env(0.02, 0.3, 0.4, 0.5), 0.4, 0.4)
	arp.vibrato_rate = 4.0
	arp.vibrato_depth = 0.015
	s.voices = [pad, drone, arp]

	var scale := AudioScaleDef.new()
	scale.root_midi = 57
	scale.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MINOR

	var chord := AudioMusicDef.new()
	chord.role = AudioMusicDef.Role.CHORD
	chord.scale = scale
	chord.bpm = 60.0
	chord.bars = 4
	chord.chord_progression = PackedInt32Array([1, 6, 5, 4])
	chord.gate = 0.98
	chord.velocity = 0.5
	chord.voice_index = 0

	var bassm := AudioMusicDef.new()
	bassm.role = AudioMusicDef.Role.BASS
	bassm.scale = scale
	bassm.bpm = 60.0
	bassm.bars = 4
	bassm.chord_progression = PackedInt32Array([1, 6, 5, 4])
	bassm.velocity = 0.6
	bassm.voice_index = 1

	var arpm := AudioMusicDef.new()
	arpm.role = AudioMusicDef.Role.ARPEGGIO
	arpm.scale = scale
	arpm.bpm = 60.0
	arpm.bars = 4
	arpm.chord_progression = PackedInt32Array([1, 6, 5, 4])
	arpm.note_length = 0.25
	arpm.gate = 0.9
	arpm.velocity = 0.6
	arpm.random_seed = 42
	arpm.voice_index = 2

	s.music = [chord, bassm, arpm]
	return s

static func _synth_jump() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.9
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["limiter"])
	var v := _voice_tone([_osc(AudioTool.Wave.SINE, 0.8), _osc(AudioTool.Wave.SQUARE, 0.3, 4.0, 0, 0.25)], _env(0.008, 0.16, 0.0, 0.1), 0.9)
	v.glide = 0.14
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 320.0
	p.voice_index = 0
	p.notes = [_note(60, 0.07), _note(48, 0.09)]
	s.patterns = [p]
	return s

static func _synth_ui_click() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.8
	s.bus = "UI"
	var v := _voice_tone([_osc(AudioTool.Wave.SQUARE, 0.7, 0.0, 0, 0.5)], _env(0.001, 0.05, 0.0, 0.03), 0.5)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 400.0
	p.voice_index = 0
	p.notes = [_note(79, 0.05), _note(81, 0.05)]
	s.patterns = [p]
	return s

static func _synth_powerup() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.85
	s.bus = "UI"
	s.fx_chain = AudioTool.fxs_from_names(["reverb_hall", "limiter"])
	var v := _voice_tone([_osc(AudioTool.Wave.SINE, 0.7), _osc(AudioTool.Wave.SINE, 0.35, 5.0)], _env(0.004, 0.2, 0.15, 0.12), 0.85)
	v.vibrato_rate = 9.0
	v.vibrato_depth = 0.02
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 380.0
	p.voice_index = 0
	p.notes = [_note(60, 0.06), _note(64, 0.06), _note(67, 0.06), _note(72, 0.1)]
	s.patterns = [p]
	return s

static func _synth_steps() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.85
	s.bus = "SFX"
	var v := _voice_tone([_osc(AudioTool.Wave.SINE, 0.3, 0.0, -1)], _env(0.002, 0.06, 0.0, 0.04), 1.0)
	v.noise_amount = 0.75
	v.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 500.0, 0.4)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 180.0
	p.voice_index = 0
	p.pitch_jitter_cents = 10
	p.timing_jitter_ms = 25
	p.random_seed = 7
	p.notes = [_note(36, 0.06), _note(36, 0.06), _note(31, 0.06)]
	s.patterns = [p]
	return s

static func _synth_whoosh() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.8
	s.bus = "SFX"
	var v := _voice_tone([_osc(AudioTool.Wave.NOISE, 0.9)], _env(0.3, 0.3, 0.0, 0.35), 0.9)
	v.filter = _filt(AudioFilterDef.Mode.BAND_PASS, 1100.0, 0.6, 3400.0)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 120.0
	p.voice_index = 0
	p.notes = [_note(0, 1.0)]
	s.patterns = [p]
	return s

static func _synth_magic() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.85
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["delay", "reverb_hall"])
	var v := _voice_tone([_osc(AudioTool.Wave.SINE, 0.7), _osc(AudioTool.Wave.TRIANGLE, 0.3)], _env(0.005, 0.25, 0.2, 0.2), 0.8)
	v.vibrato_rate = 8.0
	v.vibrato_depth = 0.03
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 400.0
	p.voice_index = 0
	p.notes = [_note(67, 0.07), _note(72, 0.07), _note(76, 0.07), _note(79, 0.12)]
	s.patterns = [p]
	return s

static func _synth_impact() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 1.0
	s.soft_clip = 1.1
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["reverb", "limiter"])
	var v := _voice_tone([_osc(AudioTool.Wave.SINE, 0.8, 0.0, -1), _osc(AudioTool.Wave.SAW, 0.4, 0.0, -1)], _env(0.001, 0.4, 0.0, 0.3), 1.0)
	v.noise_amount = 0.5
	v.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 480.0, 0.3)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 90.0
	p.voice_index = 0
	p.notes = [_note(28, 0.5)]
	s.patterns = [p]
	return s

## FM 电钢(DX7 风格): SINE 载波 + ratio=2 调制器, 经典电钢/钟琴明亮音色
static func _synth_electric_piano() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.9
	s.soft_clip = 0.6
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["limiter"])
	var v := _voice_tone(
		[_osc(AudioTool.Wave.SINE, 0.8, 0.0, 0, 0.5, 2.0, 8.0),
		 _osc(AudioTool.Wave.SINE, 0.35, 4.0, 0, 0.5, 2.0, 12.0)],
		_env(0.002, 0.3, 0.15, 0.3), 0.9)
	v.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 7000.0, 0.2)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 200.0
	p.voice_index = 0
	p.notes = [_note(72, 0.3), _note(76, 0.3), _note(79, 0.3), _note(84, 0.5)]
	s.patterns = [p]
	return s

## 拨弦(Karplus-Strong 物理建模): 竖琴/古筝/吉他式衰减拨弦音色
static func _synth_pluck() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.9
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["reverb", "limiter"])
	var v := _voice_tone(
		[_osc(AudioTool.Wave.KARPLUS, 0.8, 0.0, 0, 0.5, 1.0, 0.0, 0.5),
		 _osc(AudioTool.Wave.KARPLUS, 0.4, 12.0, 1, 0.5, 1.0, 0.0, 0.45)],
		_env(0.001, 0.4, 0.0, 0.3), 0.9)
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 160.0
	p.voice_index = 0
	p.notes = [_note(67, 0.15), _note(64, 0.15), _note(60, 0.3), _note(67, 0.15)]
	s.patterns = [p]
	return s

## Acid Bass(TB-303 风格): SAW + 高通滤波共振 + LFO 滤波截止扫频, 经典舞曲酸性贝斯
static func _synth_acid() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.SFX
	s.master_volume = 0.9
	s.soft_clip = 0.8
	s.bus = "SFX"
	s.fx_chain = AudioTool.fxs_from_names(["distortion", "limiter"])
	var v := _voice_tone([_osc(AudioTool.Wave.SAW, 0.8)], _env(0.003, 0.3, 0.0, 0.15), 0.9)
	v.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 400.0, 0.8)
	# LFO 滤波扫频: 8Hz 正弦, cutoff 在 0.2x~1.8x 之间扫
	v.lfo.enabled = true
	v.lfo.rate = 8.0
	v.lfo.waveform = AudioOscillatorDef.Wave.SINE
	v.lfo.depth = 0.8
	v.lfo.mod_cutoff = true
	s.voices = [v]
	var p := AudioPatternDef.new()
	p.bpm = 140.0
	p.voice_index = 0
	p.notes = [_note(36, 0.4), _note(36, 0.2), _note(39, 0.2), _note(43, 0.4), _note(41, 0.4), _note(36, 0.3)]
	s.patterns = [p]
	return s

## 段落结构 BGM(intro→main→outro): 演示 sections 的强度起伏(弱-强-弱)、
## 声部启停(intro/outro 无鼓、outro 贝斯静音), 完整曲式雏形
static func _synth_sections() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.85
	s.soft_clip = 0.5
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["compressor", "delay"])

	var pad := _voice_tone([_osc(AudioTool.Wave.SINE, 0.6)], _env(0.4, 0.5, 0.8, 0.4), 0.4, -0.3)
	pad.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 1200.0, 0.2)
	var bass := _voice_tone([_osc(AudioTool.Wave.SAW, 0.7)], _env(0.01, 0.25, 0.5, 0.2), 0.7)
	bass.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 400.0, 0.3)
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 88.0, 0.2, 0.8, 0.95)
	var snare := _voice_drum(AudioVoiceDef.DrumType.SNARE, 200.0, 0.55, 0.5, 0.7)
	s.voices = [pad, bass, kick, snare]

	var scale := AudioScaleDef.new()
	scale.root_midi = 57
	scale.scale_type = AudioScaleDef.ScaleType.DORIAN
	var prog := PackedInt32Array([1, 6, 4, 5])

	# 段落辅助: 强度起伏
	var _sec := func(bars: int, intensity: float, enabled := true) -> AudioMusicSectionDef:
		var sec := AudioMusicSectionDef.new()
		sec.bars = bars
		sec.intensity = intensity
		sec.enabled = enabled
		return sec

	# 铺底: 弱→强→弱
	var ch := AudioMusicDef.new()
	ch.role = AudioMusicDef.Role.CHORD
	ch.scale = scale
	ch.bpm = 110.0
	ch.chord_progression = prog
	ch.gate = 0.95
	ch.velocity = 0.5
	ch.voice_index = 0
	ch.sections = [_sec.call(2, 0.6), _sec.call(4, 1.3), _sec.call(2, 0.5)]

	# 贝斯: intro 弱, main 强, outro 静音
	var bm := AudioMusicDef.new()
	bm.role = AudioMusicDef.Role.BASS
	bm.scale = scale
	bm.bpm = 110.0
	bm.chord_progression = prog
	bm.velocity = 0.8
	bm.voice_index = 1
	bm.sections = [_sec.call(2, 0.5), _sec.call(4, 1.4), _sec.call(2, 1.0, false)]

	# 鼓: intro/outro 无鼓(启停), main 全开
	var dk := AudioMusicDef.new()
	dk.role = AudioMusicDef.Role.DRUM
	dk.bpm = 110.0
	dk.drum_kit = AudioMusicDef.DrumKit.KICK
	dk.voice_index = 2
	dk.sections = [_sec.call(2, 1.0, false), _sec.call(4, 1.0), _sec.call(2, 1.0, false)]
	var ds := AudioMusicDef.new()
	ds.role = AudioMusicDef.Role.DRUM
	ds.bpm = 110.0
	ds.drum_kit = AudioMusicDef.DrumKit.SNARE
	ds.voice_index = 3
	ds.sections = [_sec.call(2, 1.0, false), _sec.call(4, 1.0), _sec.call(2, 1.0, false)]

	s.music = [ch, bm, dk, ds]
	return s

## House BGM: 演示鼓节奏型预设库(drum_pattern=HOUSE: 四踩/反拍镲/2-4 军鼓)
static func _synth_house() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.85
	s.soft_clip = 0.5
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["compressor", "delay"])

	var pad := _voice_tone([_osc(AudioTool.Wave.SINE, 0.6)], _env(0.4, 0.5, 0.8, 0.4), 0.4, -0.3)
	pad.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 1200.0, 0.2)
	var bass := _voice_tone([_osc(AudioTool.Wave.SAW, 0.7)], _env(0.01, 0.25, 0.5, 0.2), 0.7)
	bass.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 400.0, 0.3)
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 88.0, 0.2, 0.8, 0.95)
	var snare := _voice_drum(AudioVoiceDef.DrumType.SNARE, 200.0, 0.55, 0.5, 0.7)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.5, 0.5, 0.35)
	s.voices = [pad, bass, kick, snare, hat]

	var scale := AudioScaleDef.new()
	scale.root_midi = 57
	scale.scale_type = AudioScaleDef.ScaleType.DORIAN
	var prog := PackedInt32Array([1, 6, 4, 5])
	var house_pat := DrumPatternDef.preset("HOUSE")

	var ch := AudioMusicDef.new()
	ch.role = AudioMusicDef.Role.CHORD
	ch.scale = scale
	ch.bpm = 124.0
	ch.bars = 4
	ch.chord_progression = prog
	ch.gate = 0.95
	ch.velocity = 0.5
	ch.voice_index = 0
	var bm := AudioMusicDef.new()
	bm.role = AudioMusicDef.Role.BASS
	bm.scale = scale
	bm.bpm = 124.0
	bm.bars = 4
	bm.chord_progression = prog
	bm.velocity = 0.8
	bm.voice_index = 1
	# 鼓: 同一 HOUSE 节奏型, 分轨到 KICK/SNARE/HAT 三个声部
	var dk := AudioMusicDef.new()
	dk.role = AudioMusicDef.Role.DRUM
	dk.bpm = 124.0
	dk.bars = 4
	dk.drum_kit = AudioMusicDef.DrumKit.KICK
	dk.drum_pattern = house_pat
	dk.voice_index = 2
	var ds := AudioMusicDef.new()
	ds.role = AudioMusicDef.Role.DRUM
	ds.bpm = 124.0
	ds.bars = 4
	ds.drum_kit = AudioMusicDef.DrumKit.SNARE
	ds.drum_pattern = house_pat
	ds.voice_index = 3
	var dh := AudioMusicDef.new()
	dh.role = AudioMusicDef.Role.DRUM
	dh.bpm = 124.0
	dh.bars = 4
	dh.drum_kit = AudioMusicDef.DrumKit.HAT
	dh.drum_pattern = house_pat
	dh.voice_index = 4

	s.music = [ch, bm, dk, ds, dh]
	return s

## 综合编曲验收 BGM: 一次性演示全部新能力
##  FM 电钢铺底(9 和弦+调式交换) / Karplus 拨弦琶音 / LFO 滤波扫频 Acid 贝斯 / FM 主旋律
##  段落结构(intro→verse→chorus(+2 转调)→outro) / 鼓模式切换(verse=TRAP, chorus=BREAKBEAT)
static func _synth_showcase() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.85
	s.soft_clip = 0.6
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["compressor", "delay", "reverb_hall"])

	# —— 音色(全部新能力) ——
	var pad := _voice_tone([_osc(AudioTool.Wave.SINE, 0.6, 0.0, 0, 0.5, 2.0, 7.0)], _env(0.4, 0.6, 0.8, 0.6), 0.4, -0.3)
	pad.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 3500.0, 0.2)
	var pluck := _voice_tone(
		[_osc(AudioTool.Wave.KARPLUS, 0.8), _osc(AudioTool.Wave.KARPLUS, 0.35, 8.0, 1)],
		_env(0.001, 0.35, 0.0, 0.3), 0.6, 0.4)
	var bass := _voice_tone([_osc(AudioTool.Wave.SAW, 0.8)], _env(0.005, 0.3, 0.4, 0.2), 0.8)
	bass.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 500.0, 0.6)
	bass.lfo.enabled = true
	bass.lfo.rate = 6.0
	bass.lfo.depth = 0.7
	bass.lfo.mod_cutoff = true
	var lead := _voice_tone([_osc(AudioTool.Wave.SINE, 0.7, 0.0, 0, 0.5, 3.0, 9.0)], _env(0.01, 0.2, 0.0, 0.2), 0.5, 0.2)
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 88.0, 0.2, 0.8, 0.95)
	var snare := _voice_drum(AudioVoiceDef.DrumType.SNARE, 200.0, 0.55, 0.5, 0.7)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.5, 0.5, 0.35)
	s.voices = [pad, pluck, bass, lead, kick, snare, hat]

	# —— D 多利亚, i-VI-III-VII 进行, 9 和弦调式交换 ——
	var scale := AudioScaleDef.new()
	scale.root_midi = 62
	scale.scale_type = AudioScaleDef.ScaleType.DORIAN
	var prog := PackedInt32Array([1, 6, 4, 5])
	var quality := {
		1: AudioMusicDef.ChordType.MINOR9,
		6: AudioMusicDef.ChordType.MAJOR9,
		4: AudioMusicDef.ChordType.MINOR7,
		5: AudioMusicDef.ChordType.DOMINANT7,
	}

	# —— 段落: intro(2) → verse(4) → chorus(4, +2 转调) → outro(2) ——
	var sec := func(bars: int, intensity: float, enabled := true, transpose := 0) -> AudioMusicSectionDef:
		var x := AudioMusicSectionDef.new()
		x.bars = bars
		x.intensity = intensity
		x.enabled = enabled
		x.transpose_semitones = transpose
		return x
	var all := [sec.call(2, 0.6), sec.call(4, 1.0), sec.call(4, 1.4, true, 2), sec.call(2, 0.5)]
	var bass_secs := [sec.call(2, 1.0, false), sec.call(4, 1.0), sec.call(4, 1.4, true, 2), sec.call(2, 1.0, false)]
	var lead_secs := [sec.call(2, 1.0, false), sec.call(4, 1.0, false), sec.call(4, 1.2, true, 2), sec.call(2, 1.0, false)]
	var drum_off := func(bars: int) -> AudioMusicSectionDef: return sec.call(bars, 1.0, false)
	var drum_on := func(bars: int) -> AudioMusicSectionDef: return sec.call(bars, 1.0, true)

	var pad_m := AudioMusicDef.new()
	pad_m.role = AudioMusicDef.Role.CHORD
	pad_m.scale = scale
	pad_m.bpm = 110.0
	pad_m.chord_progression = prog
	pad_m.chord_quality = quality
	pad_m.gate = 0.95
	pad_m.velocity = 0.5
	pad_m.voice_index = 0
	pad_m.sections.assign(all)
	var pluck_m := AudioMusicDef.new()
	pluck_m.role = AudioMusicDef.Role.ARPEGGIO
	pluck_m.scale = scale
	pluck_m.bpm = 110.0
	pluck_m.chord_progression = prog
	pluck_m.chord_quality = quality
	pluck_m.note_length = 0.25
	pluck_m.gate = 0.8
	pluck_m.velocity = 0.6
	pluck_m.voice_index = 1
	pluck_m.sections.assign(all)
	var bass_m := AudioMusicDef.new()
	bass_m.role = AudioMusicDef.Role.BASS
	bass_m.scale = scale
	bass_m.bpm = 110.0
	bass_m.chord_progression = prog
	bass_m.velocity = 0.85
	bass_m.voice_index = 2
	bass_m.sections.assign(bass_secs)
	var lead_m := AudioMusicDef.new()
	lead_m.role = AudioMusicDef.Role.MELODY
	lead_m.scale = scale
	lead_m.bpm = 110.0
	lead_m.chord_progression = prog
	lead_m.note_length = 0.5
	lead_m.gate = 0.85
	lead_m.velocity = 0.9
	lead_m.voice_index = 3
	lead_m.sections.assign(lead_secs)

	# —— 鼓: verse=TRAP, chorus=BREAKBEAT(各分 3 轨), intro/outro 静音 ——
	var trap := DrumPatternDef.preset("TRAP")
	var breakb := DrumPatternDef.preset("BREAKBEAT")
	var _ddrum := func(kit: int, pat: DrumPatternDef, secs: Array) -> AudioMusicDef:
		var dd := AudioMusicDef.new()
		dd.role = AudioMusicDef.Role.DRUM
		dd.bpm = 110.0
		dd.drum_kit = kit
		dd.drum_pattern = pat
		dd.voice_index = 4
		dd.sections.assign(secs)
		return dd
	var t_on := [drum_off.call(2), drum_on.call(4), drum_off.call(4), drum_off.call(2)]
	var b_on := [drum_off.call(2), drum_off.call(4), drum_on.call(4), drum_off.call(2)]
	# kick=voice4, snare=voice5, hat=voice6
	var dk_t: AudioMusicDef = _ddrum.call(AudioMusicDef.DrumKit.KICK, trap, t_on)
	dk_t.voice_index = 4
	var ds_t: AudioMusicDef = _ddrum.call(AudioMusicDef.DrumKit.SNARE, trap, t_on)
	ds_t.voice_index = 5
	var dh_t: AudioMusicDef = _ddrum.call(AudioMusicDef.DrumKit.HAT, trap, t_on)
	dh_t.voice_index = 6
	var dk_b: AudioMusicDef = _ddrum.call(AudioMusicDef.DrumKit.KICK, breakb, b_on)
	dk_b.voice_index = 4
	var ds_b: AudioMusicDef = _ddrum.call(AudioMusicDef.DrumKit.SNARE, breakb, b_on)
	ds_b.voice_index = 5
	var dh_b: AudioMusicDef = _ddrum.call(AudioMusicDef.DrumKit.HAT, breakb, b_on)
	dh_b.voice_index = 6

	s.music = [pad_m, pluck_m, bass_m, lead_m, dk_t, ds_t, dh_t, dk_b, ds_b, dh_b]
	return s
static func _synth_jazz() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.85
	s.soft_clip = 0.6
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["compressor", "reverb"])

	var pad := _voice_tone([_osc(AudioTool.Wave.SINE, 0.6, 0.0, 0, 0.5, 2.0, 6.0)], _env(0.1, 0.3, 0.8, 0.5), 0.35, -0.3)
	pad.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 3000.0, 0.2)
	var bass := _voice_tone([_osc(AudioTool.Wave.SAW, 0.6)], _env(0.01, 0.25, 0.6, 0.25), 0.7)
	bass.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 450.0, 0.3)
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 80.0, 0.2, 0.8, 0.9)
	var snare := _voice_drum(AudioVoiceDef.DrumType.SNARE, 200.0, 0.5, 0.45, 0.6)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.5, 0.5, 0.3)
	s.voices = [pad, bass, kick, snare, hat]

	var scale := AudioScaleDef.new()
	scale.root_midi = 60
	scale.scale_type = AudioScaleDef.ScaleType.MAJOR
	var prog := PackedInt32Array([2, 5, 1, 6])
	var quality := {
		2: AudioMusicDef.ChordType.MINOR7,
		5: AudioMusicDef.ChordType.DOMINANT9,
		1: AudioMusicDef.ChordType.MAJOR9,
		6: AudioMusicDef.ChordType.MINOR7,
	}

	var ch_a := AudioMusicSectionDef.new()
	ch_a.bars = 4
	ch_a.intensity = 0.8
	var ch_b := AudioMusicSectionDef.new()
	ch_b.bars = 4
	ch_b.intensity = 1.2
	ch_b.transpose_semitones = 2

	var ch := AudioMusicDef.new()
	ch.role = AudioMusicDef.Role.CHORD
	ch.scale = scale
	ch.bpm = 120.0
	ch.chord_progression = prog
	ch.chord_quality = quality
	ch.gate = 0.95
	ch.velocity = 0.5
	ch.voice_index = 0
	ch.sections = [ch_a, ch_b]
	var bm := AudioMusicDef.new()
	bm.role = AudioMusicDef.Role.BASS
	bm.scale = scale
	bm.bpm = 120.0
	bm.chord_progression = prog
	bm.chord_quality = quality
	bm.velocity = 0.8
	bm.voice_index = 1
	bm.sections = [ch_a.duplicate(), ch_b.duplicate()]

	var swing_pat := DrumPatternDef.new()
	swing_pat.style = "JAZZ_SWING"
	swing_pat.steps = 16
	swing_pat.swing = 0.3
	swing_pat.rows = {
		"KICK": "K.......K.......",
		"SNARE": "....S.......S...",
		"HAT_CLOSED": "..x.x.x.x.x.x.x.",
	}
	var dk := AudioMusicDef.new()
	dk.role = AudioMusicDef.Role.DRUM
	dk.bpm = 120.0
	dk.bars = 8
	dk.drum_kit = AudioMusicDef.DrumKit.KICK
	dk.drum_pattern = swing_pat
	dk.voice_index = 2
	var ds := AudioMusicDef.new()
	ds.role = AudioMusicDef.Role.DRUM
	ds.bpm = 120.0
	ds.bars = 8
	ds.drum_kit = AudioMusicDef.DrumKit.SNARE
	ds.drum_pattern = swing_pat
	ds.voice_index = 3
	var dh := AudioMusicDef.new()
	dh.role = AudioMusicDef.Role.DRUM
	dh.bpm = 120.0
	dh.bars = 8
	dh.drum_kit = AudioMusicDef.DrumKit.HAT
	dh.drum_pattern = swing_pat
	dh.voice_index = 4

	s.music = [ch, bm, dk, ds, dh]
	return s



## 8-bit 复古(Chiptune): SQUARE 主奏 + 方波贝斯 + 三角琶音 + 16 分镲 —— 减法合成 + 琶音编曲 + 鼓模式
static func _synth_chiptune() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.85
	s.soft_clip = 0.5
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["compressor"])
	var lead := _voice_tone([_osc(AudioTool.Wave.SQUARE, 0.7, 0.0, 1)], _env(0.005, 0.1, 0.0, 0.08), 0.6)
	var bass := _voice_tone([_osc(AudioTool.Wave.SQUARE, 0.8)], _env(0.002, 0.2, 0.0, 0.1), 0.8)
	var arp := _voice_tone([_osc(AudioTool.Wave.TRIANGLE, 0.8)], _env(0.002, 0.15, 0.0, 0.1), 0.5)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.6, 0.5, 0.35)
	s.voices = [lead, bass, arp, hat]
	var scale := AudioScaleDef.new()
	scale.root_midi = 60
	scale.scale_type = AudioScaleDef.ScaleType.MAJOR
	var prog := PackedInt32Array([1, 5, 6, 4])
	var mel := AudioMusicDef.new()
	mel.role = AudioMusicDef.Role.MELODY
	mel.scale = scale
	mel.bpm = 140.0
	mel.bars = 4
	mel.chord_progression = prog
	mel.note_length = 0.25
	mel.gate = 0.9
	mel.velocity = 0.9
	mel.voice_index = 0
	var bas := AudioMusicDef.new()
	bas.role = AudioMusicDef.Role.BASS
	bas.scale = scale
	bas.bpm = 140.0
	bas.bars = 4
	bas.chord_progression = prog
	bas.velocity = 0.85
	bas.voice_index = 1
	var ar := AudioMusicDef.new()
	ar.role = AudioMusicDef.Role.ARPEGGIO
	ar.scale = scale
	ar.bpm = 140.0
	ar.bars = 4
	ar.chord_progression = prog
	ar.note_length = 0.125
	ar.gate = 0.9
	ar.velocity = 0.5
	ar.voice_index = 2
	var dh := AudioMusicDef.new()
	dh.role = AudioMusicDef.Role.DRUM
	dh.bpm = 140.0
	dh.bars = 4
	dh.drum_kit = AudioMusicDef.DrumKit.HAT
	dh.drum_pattern = DrumPatternDef.preset("TECHNO")
	dh.voice_index = 3
	s.music = [mel, bas, ar, dh]
	return s

## 摇滚(Rock): 失真吉他 power chord + 方波贝斯 + 重军鼓 —— 失真效果 + 鼓模式 + 挂留和弦
static func _synth_rock() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.9
	s.soft_clip = 0.8
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["distortion", "compressor"])
	var gtr := _voice_tone([_osc(AudioTool.Wave.SQUARE, 0.7, 0.0, 0, 0.25), _osc(AudioTool.Wave.SAW, 0.4)], _env(0.003, 0.2, 0.0, 0.1), 0.9)
	gtr.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 3000.0, 0.4)
	var bass := _voice_tone([_osc(AudioTool.Wave.SQUARE, 0.8, 0.0, -1)], _env(0.002, 0.3, 0.0, 0.15), 0.9)
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 90.0, 0.2, 0.85, 1.0)
	var snare := _voice_drum(AudioVoiceDef.DrumType.SNARE, 190.0, 0.6, 0.55, 0.9)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.5, 0.5, 0.4)
	s.voices = [gtr, bass, kick, snare, hat]
	var scale := AudioScaleDef.new()
	scale.root_midi = 57
	scale.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MINOR
	var prog := PackedInt32Array([1, 6, 4, 5])
	var ch := AudioMusicDef.new()
	ch.role = AudioMusicDef.Role.CHORD
	ch.scale = scale
	ch.bpm = 130.0
	ch.bars = 4
	ch.chord_progression = prog
	ch.chord_type = AudioMusicDef.ChordType.SUS2
	ch.gate = 0.9
	ch.velocity = 0.7
	ch.voice_index = 0
	var bas := AudioMusicDef.new()
	bas.role = AudioMusicDef.Role.BASS
	bas.scale = scale
	bas.bpm = 130.0
	bas.bars = 4
	bas.chord_progression = prog
	bas.velocity = 0.9
	bas.voice_index = 1
	var dk := AudioMusicDef.new()
	dk.role = AudioMusicDef.Role.DRUM
	dk.bpm = 130.0
	dk.bars = 4
	dk.drum_kit = AudioMusicDef.DrumKit.KICK
	dk.drum_pattern = DrumPatternDef.preset("ROCK")
	dk.voice_index = 2
	var ds := AudioMusicDef.new()
	ds.role = AudioMusicDef.Role.DRUM
	ds.bpm = 130.0
	ds.bars = 4
	ds.drum_kit = AudioMusicDef.DrumKit.SNARE
	ds.drum_pattern = DrumPatternDef.preset("ROCK")
	ds.voice_index = 3
	var dh := AudioMusicDef.new()
	dh.role = AudioMusicDef.Role.DRUM
	dh.bpm = 130.0
	dh.bars = 4
	dh.drum_kit = AudioMusicDef.DrumKit.HAT
	dh.drum_pattern = DrumPatternDef.preset("ROCK")
	dh.voice_index = 4
	s.music = [ch, bas, dk, ds, dh]
	return s

## 陷阱(Trap): TRAP 三连鼓 + 重低音(LFO 抽吸) + FM 钟 —— 鼓模式(三连/切分) + FM + LFO
static func _synth_trap() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.9
	s.soft_clip = 0.7
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["compressor", "delay"])
	var sub := _voice_tone([_osc(AudioTool.Wave.SINE, 0.9)], _env(0.01, 0.3, 0.0, 0.2), 0.9)
	sub.lfo.enabled = true
	sub.lfo.rate = 8.0
	sub.lfo.depth = 0.5
	sub.lfo.mod_volume = true
	var bell := _voice_tone([_osc(AudioTool.Wave.SINE, 0.7, 0.0, 0, 0.5, 2.0, 10.0)], _env(0.002, 0.5, 0.0, 0.5), 0.5)
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 85.0, 0.2, 0.9, 1.0)
	var snare := _voice_drum(AudioVoiceDef.DrumType.SNARE, 200.0, 0.6, 0.5, 0.8)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_CLOSED, 0.0, 0.5, 0.5, 0.35)
	s.voices = [sub, bell, kick, snare, hat]
	var scale := AudioScaleDef.new()
	scale.root_midi = 50
	scale.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MINOR
	var prog := PackedInt32Array([1, 6, 4, 5])
	var bas := AudioMusicDef.new()
	bas.role = AudioMusicDef.Role.BASS
	bas.scale = scale
	bas.bpm = 140.0
	bas.bars = 4
	bas.chord_progression = prog
	bas.velocity = 0.9
	bas.voice_index = 0
	var bl := AudioMusicDef.new()
	bl.role = AudioMusicDef.Role.MELODY
	bl.scale = scale
	bl.bpm = 140.0
	bl.bars = 4
	bl.chord_progression = prog
	bl.note_length = 0.5
	bl.gate = 0.6
	bl.velocity = 0.7
	bl.voice_index = 1
	var dk := AudioMusicDef.new()
	dk.role = AudioMusicDef.Role.DRUM
	dk.bpm = 140.0
	dk.bars = 4
	dk.drum_kit = AudioMusicDef.DrumKit.KICK
	dk.drum_pattern = DrumPatternDef.preset("TRAP")
	dk.voice_index = 2
	var ds := AudioMusicDef.new()
	ds.role = AudioMusicDef.Role.DRUM
	ds.bpm = 140.0
	ds.bars = 4
	ds.drum_kit = AudioMusicDef.DrumKit.SNARE
	ds.drum_pattern = DrumPatternDef.preset("TRAP")
	ds.voice_index = 3
	var dh := AudioMusicDef.new()
	dh.role = AudioMusicDef.Role.DRUM
	dh.bpm = 140.0
	dh.bars = 4
	dh.drum_kit = AudioMusicDef.DrumKit.HAT
	dh.drum_pattern = DrumPatternDef.preset("TRAP")
	dh.voice_index = 4
	s.music = [bas, bl, dk, ds, dh]
	return s

## 电影/管弦(Cinematic): 弦乐 pad(失谐叠加) + 低音 drone + 定音鼓 —— 减法叠加 + 7 和弦 + 慢速长音
static func _synth_cinematic() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.9
	s.soft_clip = 0.6
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["reverb_hall", "compressor"])
	var strings := _voice_tone(
		[_osc(AudioTool.Wave.SAW, 0.5, -8.0), _osc(AudioTool.Wave.SAW, 0.5, 8.0), _osc(AudioTool.Wave.TRIANGLE, 0.6)],
		_env(1.0, 1.5, 0.9, 1.5), 0.6)
	strings.filter = _filt(AudioFilterDef.Mode.LOW_PASS, 1500.0, 0.2)
	var drone := _voice_tone([_osc(AudioTool.Wave.SINE, 0.7, 0.0, -1)], _env(2.0, 1.0, 0.9, 2.0), 0.5)
	var timp := _voice_drum(AudioVoiceDef.DrumType.TOM, 70.0, 0.2, 0.9, 0.9)
	var kick := _voice_drum(AudioVoiceDef.DrumType.KICK, 60.0, 0.2, 0.8, 1.0)
	s.voices = [strings, drone, timp, kick]
	var scale := AudioScaleDef.new()
	scale.root_midi = 55
	scale.scale_type = AudioScaleDef.ScaleType.DORIAN
	var prog := PackedInt32Array([1, 6, 4, 5])
	var ch := AudioMusicDef.new()
	ch.role = AudioMusicDef.Role.PAD
	ch.scale = scale
	ch.bpm = 70.0
	ch.bars = 8
	ch.chord_progression = prog
	ch.chord_quality = {1: AudioMusicDef.ChordType.MAJOR7, 6: AudioMusicDef.ChordType.MINOR7, 4: AudioMusicDef.ChordType.MAJOR7, 5: AudioMusicDef.ChordType.DOMINANT7}
	ch.gate = 0.95
	ch.velocity = 0.7
	ch.voice_index = 0
	var dn := AudioMusicDef.new()
	dn.role = AudioMusicDef.Role.BASS
	dn.scale = scale
	dn.bpm = 70.0
	dn.bars = 8
	dn.chord_progression = prog
	dn.velocity = 0.7
	dn.voice_index = 1
	var dt := AudioMusicDef.new()
	dt.role = AudioMusicDef.Role.DRUM
	dt.bpm = 70.0
	dt.bars = 8
	dt.drum_kit = AudioMusicDef.DrumKit.KICK
	dt.drum_pattern = DrumPatternDef.preset("BALLAD")
	dt.voice_index = 3
	var dt2 := AudioMusicDef.new()
	dt2.role = AudioMusicDef.Role.DRUM
	dt2.bpm = 70.0
	dt2.bars = 8
	dt2.drum_kit = AudioMusicDef.DrumKit.KICK
	dt2.drum_pattern = DrumPatternDef.new()
	dt2.drum_pattern.style = "TIMPI"
	dt2.drum_pattern.steps = 8
	dt2.drum_pattern.rows = {"KICK": "T...T..."}
	dt2.voice_index = 2
	s.music = [ch, dn, dt, dt2]
	return s

## 世界/拨弦(World): Karplus 竖琴琶音 + 笛音旋律 + 五声音阶 —— 物理建模 + 音阶 + 开镲点缀
static func _synth_world() -> AudioSynthDef:
	var s := AudioSynthDef.new()
	s.category = AudioSynthDef.Category.BGM
	s.sample_rate = 22050
	s.loop = true
	s.master_volume = 0.85
	s.bus = "BGM"
	s.fx_chain = AudioTool.fxs_from_names(["reverb", "delay"])
	var harp := _voice_tone(
		[_osc(AudioTool.Wave.KARPLUS, 0.8), _osc(AudioTool.Wave.KARPLUS, 0.3, 6.0, 1)],
		_env(0.001, 0.5, 0.0, 0.4), 0.7)
	var flute := _voice_tone([_osc(AudioTool.Wave.TRIANGLE, 0.8)], _env(0.1, 0.3, 0.6, 0.4), 0.5)
	var hat := _voice_drum(AudioVoiceDef.DrumType.HAT_OPEN, 0.0, 0.4, 0.4, 0.25)
	s.voices = [harp, flute, hat]
	var scale := AudioScaleDef.new()
	scale.root_midi = 60
	scale.scale_type = AudioScaleDef.ScaleType.PENTATONIC_MAJOR
	var prog := PackedInt32Array([1, 4, 5, 1])
	var ar := AudioMusicDef.new()
	ar.role = AudioMusicDef.Role.ARPEGGIO
	ar.scale = scale
	ar.bpm = 90.0
	ar.bars = 4
	ar.chord_progression = prog
	ar.note_length = 0.25
	ar.gate = 0.85
	ar.velocity = 0.7
	ar.voice_index = 0
	var fl := AudioMusicDef.new()
	fl.role = AudioMusicDef.Role.MELODY
	fl.scale = scale
	fl.bpm = 90.0
	fl.bars = 4
	fl.chord_progression = prog
	fl.note_length = 0.5
	fl.gate = 0.9
	fl.velocity = 0.7
	fl.voice_index = 1
	var dh := AudioMusicDef.new()
	dh.role = AudioMusicDef.Role.DRUM
	dh.bpm = 90.0
	dh.bars = 4
	dh.drum_kit = AudioMusicDef.DrumKit.HAT_OPEN
	dh.drum_pattern = DrumPatternDef.new()
	dh.drum_pattern.style = "WORLD_OPEN"
	dh.drum_pattern.steps = 16
	dh.drum_pattern.rows = {"HAT_OPEN": "....h.......h..."}
	dh.voice_index = 2
	s.music = [ar, fl, dh]
	return s
