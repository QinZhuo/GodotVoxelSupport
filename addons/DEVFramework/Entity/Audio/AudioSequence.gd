@tool
## 音符序列展开器 — 把 AudioSynthDef 中的显式序列与自动编曲展开成一串音符事件
class_name AudioSequence

## 音符事件字段：voice_index / start / duration(采样帧) / midi / velocity
## 鼓事件 midi 为 0（由音色鼓类型决定）

static func expand(def: AudioSynthDef) -> Array:
	var events: Array = []
	for p in def.patterns:
		_append_pattern(events, p, def.sample_rate)
	for m in def.music:
		_append_music(events, m, def.sample_rate)
	return events

static func _append_pattern(events: Array, p: AudioPatternDef, sr: int) -> void:
	var fpp := 60.0 / p.bpm * sr  # 每拍采样帧
	var cursor := 0.0
	var mine: Array = []
	for n in p.notes:
		cursor += n.delay_beats * fpp
		if n.is_rest:
			cursor += n.length_beats * fpp
			continue
		mine.append({
			"voice_index": p.voice_index,
			"start": int(cursor),
			"duration": int(n.length_beats * fpp),
			"midi": n.midi,
			"velocity": n.velocity,
		})
		cursor += n.length_beats * fpp
	var rng := RandomNumberGenerator.new()
	rng.seed = p.random_seed
	_finalize(mine, rng, p.pitch_jitter_cents, p.timing_jitter_ms, sr)
	events.append_array(mine)

static func _append_music(events: Array, m: AudioMusicDef, sr: int) -> void:
	var fpp := 60.0 / m.bpm * sr
	var bar_frames := 4.0 * fpp  # 默认 4/4 拍
	var chord_intervals := _chord_intervals(m.chord_type)
	var rng := RandomNumberGenerator.new()
	rng.seed = m.random_seed
	var scale_notes := _build_scale_pool(m.scale, m.octave)

	var melody_idx := _nearest_scale_index(scale_notes, m.scale.degree_to_midi(1) + 12 * m.octave)
	var mine: Array = []

	for bar in m.bars:
		var degree := m.chord_progression[bar % maxi(1, m.chord_progression.size())]
		var root := m.scale.degree_to_midi(degree) + 12 * m.octave
		var bar_start := bar * int(bar_frames)
		match m.role:
			m.Role.CHORD, m.Role.PAD:
				var dur := int(bar_frames * m.gate)
				for iv in chord_intervals:
					mine.append(_ev(m.voice_index, bar_start, dur, root + iv, m.velocity))
			m.Role.ARPEGGIO:
				var step := m.note_length
				var steps := 4.0 / step
				var step_frames := step * fpp
				var oct := 0
				for s in int(steps):
					var idx := s % chord_intervals.size()
					if idx == 0 and s > 0:
						oct += 1
					var midi: int = root + chord_intervals[idx] + 12 * oct
					var start := bar_start + int(s * step_frames)
					mine.append(_ev(m.voice_index, start, int(step_frames * m.gate), midi, m.velocity * _twitch(rng)))
			m.Role.BASS:
				var steps := 2
				var sdur := bar_frames / steps
				for s in steps:
					mine.append(_ev(m.voice_index, bar_start + int(s * sdur), int(sdur * m.gate), root - 12, m.velocity))
			m.Role.MELODY:
				var steps := 4.0 / m.note_length
				var step_frames := m.note_length * fpp
				for s in int(steps):
					# 摇摆偏移
					var off := 0.0
					if m.swing > 0.0 and s % 2 == 1:
						off = m.swing * fpp
					var start := bar_start + int(s * step_frames + off)
					# 随机游走选音
					var step_n := _rng_step(rng)
					melody_idx = clampi(melody_idx + step_n, 0, scale_notes.size() - 1)
					var midi: int = scale_notes[melody_idx]
					mine.append(_ev(m.voice_index, start, int(step_frames * m.gate), midi, m.velocity * _twitch(rng)))
			m.Role.DRUM:
				# 4/4 鼓组，按 drum_kit 分轨
				match m.drum_kit:
					m.DrumKit.FULL, m.DrumKit.KICK:
						mine.append({"voice_index": m.voice_index, "start": bar_start, "duration": int(fpp * 0.9), "midi": 0, "velocity": 0.9})
						mine.append({"voice_index": m.voice_index, "start": bar_start + int(2.0 * fpp), "duration": int(fpp * 0.9), "midi": 0, "velocity": 0.85})
					m.DrumKit.FULL, m.DrumKit.SNARE:
						mine.append({"voice_index": m.voice_index, "start": bar_start + int(1.0 * fpp), "duration": int(fpp * 0.5), "midi": 0, "velocity": 0.7})
						mine.append({"voice_index": m.voice_index, "start": bar_start + int(3.0 * fpp), "duration": int(fpp * 0.5), "midi": 0, "velocity": 0.7})
					m.DrumKit.FULL, m.DrumKit.HAT:
						for h in 8:
							var vel := 0.2
							if h == 6:
								vel = 0.4
							mine.append({"voice_index": m.voice_index, "start": bar_start + int(h * 0.5 * fpp), "duration": int(fpp * 0.4), "midi": 0, "velocity": vel})
					m.DrumKit.HAT_OPEN:
						mine.append({"voice_index": m.voice_index, "start": bar_start + int(6.5 * fpp), "duration": int(fpp * 1.5), "midi": 0, "velocity": 0.5})

	_finalize(mine, rng, m.pitch_jitter_cents, m.timing_jitter_ms, sr)
	events.append_array(mine)

static func _ev(voice_index: int, start: int, duration: int, midi: int, velocity: float) -> Dictionary:
	return {"voice_index": voice_index, "start": start, "duration": maxi(1, duration), "midi": midi, "velocity": clampf(velocity, 0.0, 1.0)}

## 构建以根音为中心、覆盖若干八度的音阶音池
static func _build_scale_pool(scale: AudioScaleDef, octave: int) -> Array:
	var intervals := AudioScaleDef.get_intervals(scale.scale_type)
	var out: Array = []
	var base := scale.root_midi + 12 * octave
	for oct in range(-1, 3):
		for iv in intervals:
			out.append(base + iv + 12 * oct)
	return out

static func _nearest_scale_index(pool: Array, target: int) -> int:
	var best := 0
	var bd := 1 << 30
	for i in pool.size():
		var d := absi(int(pool[i]) - target)
		if d < bd:
			bd = d
			best = i
	return best

## 加权随机步——倾向小步(级进)，偶尔跳进，听感更自然
static func _rng_step(rng: RandomNumberGenerator) -> int:
	var r := rng.randf()
	if r < 0.45:
		return rng.randi_range(0, 0) if r < 0.2 else (1 if r < 0.32 else -1)
	# 0.45~0.65 跳 2 音
	return rng.randi_range(-2, 2) if r < 0.7 else rng.randi_range(-3, 3)

static func _twitch(rng: RandomNumberGenerator) -> float:
	return rng.randf_range(0.92, 1.0)

## 人性化: 音高抖动(音分) + 触发时间抖动(毫秒), 消除重复机械感
static func _finalize(mine: Array, rng: RandomNumberGenerator, cents: float, ms: float, sr: int) -> void:
	if cents > 0.0:
		for e in mine:
			e["pitch_cents"] = cents * rng.randf_range(-1.0, 1.0)
	if ms > 0.0:
		var ms_frames := ms * sr / 1000.0
		for e in mine:
			e["start"] = maxi(0, int(e.start) + int(rng.randf_range(-ms_frames, ms_frames)))

static func _chord_intervals(t: AudioMusicDef.ChordType) -> PackedInt32Array:
	match t:
		AudioMusicDef.ChordType.MAJOR_TRIAD: return PackedInt32Array([0, 4, 7])
		AudioMusicDef.ChordType.MINOR_TRIAD: return PackedInt32Array([0, 3, 7])
		AudioMusicDef.ChordType.DIMINISHED: return PackedInt32Array([0, 3, 6])
		AudioMusicDef.ChordType.AUGMENTED: return PackedInt32Array([0, 4, 8])
		AudioMusicDef.ChordType.SUS2: return PackedInt32Array([0, 2, 7])
		AudioMusicDef.ChordType.SUS4: return PackedInt32Array([0, 5, 7])
		AudioMusicDef.ChordType.MAJOR7: return PackedInt32Array([0, 4, 7, 11])
		AudioMusicDef.ChordType.MINOR7: return PackedInt32Array([0, 3, 7, 10])
		AudioMusicDef.ChordType.DOMINANT7: return PackedInt32Array([0, 4, 7, 10])
	return PackedInt32Array([0, 4, 7])