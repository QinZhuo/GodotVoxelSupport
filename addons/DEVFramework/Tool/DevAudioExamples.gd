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
			var stream := AudioTool.generate(def)
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
	return d

# —— 便捷构造 ——
static func _osc(wave: int, level := 1.0, detune := 0.0, oct := 0, pw := 0.5) -> AudioOscillatorDef:
	var o := AudioOscillatorDef.new()
	o.waveform = wave
	o.level = level
	o.detune_cents = detune
	o.octave_shift = oct
	o.pulse_width = pw
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

