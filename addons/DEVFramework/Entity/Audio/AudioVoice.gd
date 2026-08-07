@tool
## 音色渲染器 — 把一串音符事件渲染成单声道采样（逐采样合成，支持流式/循环）
class_name AudioVoice

var def: AudioVoiceDef
var sample_rate := 44100.0
var events: Array = []
var rng := RandomNumberGenerator.new()

var _cursor := 0
var _event_idx := 0
var _notes: Array = []

## 发声中的音符状态（音调类）
class Tone:
	var start := 0
	var gate := 0
	var target_freq := 440.0
	var freq := 440.0
	var velocity := 1.0
	var vibrato_phase := 0.0
	var phases: PackedFloat32Array
	var adsr: AudioTool.ADSR
	var filter: AudioTool.SVFilter
	var removed := false

## 打击乐事件状态
class Drum:
	var start := 0
	var gate := 0
	var velocity := 1.0
	var phase := 0.0
	var freq := 90.0
	var removed := false

func _init(def_: AudioVoiceDef, sr: float) -> void:
	def = def_
	sample_rate = sr
	rng.seed = 123456

func reset_stream() -> void:
	_cursor = 0
	_event_idx = 0
	_notes.clear()

## 从当前游标渲染 count 帧，返回单声道采样
func render_to_array(count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	for i in count:
		out[i] = _render_sample(_cursor)
		_cursor += 1
	return out

## 混合剩余输入事件（用于外层校验/计长）
func last_frame() -> int:
	var f := 0
	for e in events:
		f = maxi(f, int(e.start) + int(e.duration))
	return f

func _render_sample(index: int) -> float:
	while _event_idx < events.size() and int(events[_event_idx].start) <= index:
		_trigger(events[_event_idx], index)
		_event_idx += 1
	if def.kind == AudioVoiceDef.Kind.DRUM:
		return _render_drum(index)
	var sum := 0.0
	var i := 0
	while i < _notes.size():
		var n: Tone = _notes[i]
		if n.removed:
			_notes.remove_at(i)
			continue
		sum += _render_tone(n, index)
		i += 1
	return sum

func _trigger(e: Dictionary, index: int) -> void:
	if def.kind == AudioVoiceDef.Kind.DRUM:
		var d := Drum.new()
		d.start = index
		d.gate = int(e.duration)
		d.velocity = float(e.velocity)
		d.freq = def.drum_freq * (3.0 if def.drum_type in [AudioVoiceDef.DrumType.TOM] else 1.0)
		_notes.append(d)
		return
	var n := Tone.new()
	n.start = index
	n.gate = int(e.duration)
	n.velocity = float(e.velocity)
	n.target_freq = AudioTool.midi_to_freq(int(e.midi)) * pow(2.0, float(e.get("pitch_cents", 0.0)) / 1200.0)
	n.freq = n.target_freq * (0.5 if def.glide > 0.0 else 1.0)
	n.phases = PackedFloat32Array()
	n.phases.resize(def.oscillators.size())
	n.adsr = AudioTool.ADSR.new(sample_rate)
	n.adsr.attack = def.envelope.attack
	n.adsr.decay = def.envelope.decay
	n.adsr.sustain = def.envelope.sustain
	n.adsr.release = def.envelope.release
	n.adsr.curve = def.envelope.curve
	if def.filter and def.filter.enabled:
		n.filter = AudioTool.SVFilter.new(sample_rate, def.filter.cutoff, def.filter.resonance, def.filter.mode)
	n.adsr.note_on()
	_notes.append(n)

func _render_tone(n: Tone, index: int) -> float:
	if not n.removed and index >= n.start + n.gate:
		n.adsr.note_off()
	# 颤音(音分)
	if def.vibrato_depth > 0.0:
		var vib := sin(n.vibrato_phase * TAU) * def.vibrato_depth * 100.0
		n.freq = n.target_freq * pow(2.0, vib / 1200.0)
		n.vibrato_phase += def.vibrato_rate / sample_rate
	elif def.glide > 0.0:
		var a := 1.0 - exp(-1.0 / (maxf(def.glide, 0.0001) * sample_rate))
		n.freq = lerpf(n.freq, n.target_freq, a)
	var env := n.adsr.process()
	if n.adsr.is_done():
		n.removed = true
		return 0.0
	# 振荡器叠加
	var wave := 0.0
	for oi in def.oscillators.size():
		var od := def.oscillators[oi]
		var f := n.target_freq * pow(2.0, (od.detune_cents + od.octave_shift * 1200.0) / 1200.0)
		var dt := f / sample_rate
		var ph := n.phases[oi]
		wave += AudioTool.osc(od.waveform, ph, dt, od.pulse_width, rng) * od.level
		n.phases[oi] = ph + dt - floorf(ph + dt)
	# 噪声叠加
	if def.noise_amount > 0.0:
		wave += rng.randf_range(-1.0, 1.0) * def.noise_amount
	# 滤波
	if n.filter:
		var cut := n.filter.cutoff
		if def.filter.cutoff_envelope_amount != 0.0:
			cut += def.filter.cutoff_envelope_amount * env
		n.filter.cutoff = clampf(cut, 20.0, sample_rate * 0.45)
		wave = n.filter.process(wave)
	return wave * env * n.velocity

func _render_drum(index: int) -> float:
	var sum := 0.0
	var i := 0
	while i < _notes.size():
		var d: Drum = _notes[i]
		if d.removed:
			_notes.remove_at(i)
			continue
		if index >= d.start + d.gate:
			d.removed = true
			continue
		sum += _drum_sample(d, (index - d.start) / sample_rate)
		i += 1
	return sum

func _drum_sample(d: Drum, t: float) -> float:
	var noise := rng.randf_range(-1.0, 1.0)
	var tone := 0.0
	match def.drum_type:
		AudioVoiceDef.DrumType.KICK:
			var env := exp(-t * 34.0)
			var f := lerpf(d.freq * 2.6, def.drum_freq, 1.0 - exp(-t * 30.0))
			d.phase += f / sample_rate
			tone = sin(d.phase * TAU) * env * def.drum_tone
			var click := noise * exp(-t * 85.0) * def.drum_noise
			return tone + click
		AudioVoiceDef.DrumType.SNARE:
			d.phase += 200.0 / sample_rate
			tone = sin(d.phase * TAU) * exp(-t * 16.0) * def.drum_tone
			var nz := noise * exp(-t * 20.0) * def.drum_noise
			return tone * 0.4 + nz
		AudioVoiceDef.DrumType.HAT_CLOSED:
			return noise * exp(-t * 110.0) * def.drum_noise * def.drum_tone * 1.2
		AudioVoiceDef.DrumType.HAT_OPEN:
			return noise * exp(-t * 18.0) * def.drum_noise * def.drum_tone * 1.2
		AudioVoiceDef.DrumType.TOM:
			var env := exp(-t * 16.0)
			var f := lerpf(d.freq * 1.6, def.drum_freq, 1.0 - exp(-t * 18.0))
			d.phase += f / sample_rate
			return sin(d.phase * TAU) * env * def.drum_tone
		AudioVoiceDef.DrumType.CLAP:
			var bursts := 0.0
			for b in 3:
				var tb := t - b * 0.012
				if tb > 0.0:
					bursts += exp(-tb * 70.0)
			return (noise * bursts * 0.5 + sin(t * 180.0 * TAU) * exp(-t * 30.0) * def.drum_tone) * 0.8
	return 0.0