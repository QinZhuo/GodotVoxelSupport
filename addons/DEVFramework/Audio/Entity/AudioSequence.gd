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
	var rng := RandomNumberGenerator.new()
	rng.seed = m.random_seed
	var scale_notes := _build_scale_pool(m.scale, m.octave)
	var state := {
		"melody_idx": _nearest_scale_index(scale_notes, m.scale.degree_to_midi(1) + 12 * m.octave),
	}

	var mine: Array = []
	# 段落结构: sections 为空退化为单一整段(旧行为: bars + chord_progression)
	var secs: Array = m.sections
	if secs.is_empty():
		var sec := AudioMusicSectionDef.new()
		sec.bars = m.bars
		sec.chord_progression = m.chord_progression
		secs = [sec]
	var bar_cursor := 0
	for sec in secs:
		bar_cursor = _append_music_section(mine, m, sec, bar_cursor, bar_frames, fpp, rng, scale_notes, state)

	_finalize(mine, rng, m.pitch_jitter_cents, m.timing_jitter_ms, sr)
	events.append_array(mine)

## 展开一个段落(无缝拼接到 bar_start 起); 返回段结束的小节游标
static func _append_music_section(mine: Array, m: AudioMusicDef, sec: AudioMusicSectionDef, bar_start: int,
		bar_frames: float, fpp: float,
		rng: RandomNumberGenerator, scale_notes: Array, state: Dictionary) -> int:
	var sec_bars := sec.bars if sec != null else m.bars
	if sec == null or not sec.enabled:
		return bar_start + sec_bars
	var progression: PackedInt32Array = sec.chord_progression if not sec.chord_progression.is_empty() else m.chord_progression
	var vel := clampf(m.velocity * sec.intensity, 0.0, 1.0)
	var oct := sec.octave_shift
	for bar in sec_bars:
		var degree := progression[bar % maxi(1, progression.size())]
		# 和弦色彩覆盖(调式交换/借用): 该音级指定和弦类型, 否则用默认
		var ct: int = m.chord_quality.get(degree, m.chord_type) if m.chord_quality.has(degree) else m.chord_type
		var chord_intervals := _chord_intervals(ct)
		# 转调: 声部级 + 段落级叠加
		var root := m.scale.degree_to_midi(degree) + 12 * (m.octave + oct) + m.transpose_semitones + sec.transpose_semitones
		var bar_off := (bar_start + bar) * int(bar_frames)
		match m.role:
			m.Role.CHORD, m.Role.PAD:
				var dur := int(bar_frames * m.gate)
				for iv in chord_intervals:
					mine.append(_ev(m.voice_index, bar_off, dur, root + iv, vel))
			m.Role.ARPEGGIO:
				var step := m.note_length
				var steps := 4.0 / step
				var step_frames := step * fpp
				var arp_oct := 0
				for s in int(steps):
					var idx := s % chord_intervals.size()
					if idx == 0 and s > 0:
						arp_oct += 1
					var midi: int = root + chord_intervals[idx] + 12 * arp_oct
					var start := bar_off + int(s * step_frames)
					mine.append(_ev(m.voice_index, start, int(step_frames * m.gate), midi, vel * _twitch(rng)))
			m.Role.BASS:
				var steps := 2
				var sdur := bar_frames / steps
				for s in steps:
					mine.append(_ev(m.voice_index, bar_off + int(s * sdur), int(sdur * m.gate), root - 12, vel))
			m.Role.MELODY:
				var steps := 4.0 / m.note_length
				var step_frames := m.note_length * fpp
				for s in int(steps):
					# 摇摆偏移
					var off := 0.0
					if m.swing > 0.0 and s % 2 == 1:
						off = m.swing * fpp
					var start := bar_off + int(s * step_frames + off)
					# 随机游走选音(跨段延续, 旋律连贯)
					var step_n := _rng_step(rng)
					state.melody_idx = clampi(int(state.melody_idx) + step_n, 0, scale_notes.size() - 1)
					# 八度偏移 + 转调(声部级+段落级): 必须与和弦同步移调
					var midi: int = int(scale_notes[int(state.melody_idx)]) + 12 * oct + m.transpose_semitones + sec.transpose_semitones
					mine.append(_ev(m.voice_index, start, int(step_frames * m.gate), midi, vel * _twitch(rng)))
			m.Role.DRUM:
				# 节奏型模式(drum_pattern)优先: 支持切分/三连音/摇摆; 否则退回 drum_kit 固定 4/4
				if m.drum_pattern and not m.drum_pattern.rows.is_empty():
					_append_drum_pattern(mine, m, m.drum_pattern, bar_off, bar_frames, sec.intensity)
				else:
					_append_drum_kit(mine, m, bar_off, bar_frames, fpp, sec.intensity)
	return bar_start + sec_bars

## 旧版固定 4/4 鼓组(按 drum_kit 分轨); velocity 乘段强度(乐器增减/段落起伏)
static func _append_drum_kit(mine: Array, m: AudioMusicDef, bar_off: int, bar_frames: float, fpp: float, intensity: float) -> void:
	match m.drum_kit:
		m.DrumKit.FULL, m.DrumKit.KICK:
			mine.append({"voice_index": m.voice_index, "start": bar_off, "duration": int(fpp * 0.9), "midi": 0, "velocity": 0.9 * intensity})
			mine.append({"voice_index": m.voice_index, "start": bar_off + int(2.0 * fpp), "duration": int(fpp * 0.9), "midi": 0, "velocity": 0.85 * intensity})
		m.DrumKit.FULL, m.DrumKit.SNARE:
			mine.append({"voice_index": m.voice_index, "start": bar_off + int(1.0 * fpp), "duration": int(fpp * 0.5), "midi": 0, "velocity": 0.7 * intensity})
			mine.append({"voice_index": m.voice_index, "start": bar_off + int(3.0 * fpp), "duration": int(fpp * 0.5), "midi": 0, "velocity": 0.7 * intensity})
		m.DrumKit.FULL, m.DrumKit.HAT:
			for h in 8:
				var vel_h := 0.2
				if h == 6:
					vel_h = 0.4
				mine.append({"voice_index": m.voice_index, "start": bar_off + int(h * 0.5 * fpp), "duration": int(fpp * 0.4), "midi": 0, "velocity": vel_h * intensity})
		m.DrumKit.HAT_OPEN:
			mine.append({"voice_index": m.voice_index, "start": bar_off + int(6.5 * fpp), "duration": int(fpp * 1.5), "midi": 0, "velocity": 0.5 * intensity})

## 节奏型模式展开: 按 drum_kit 筛选对应鼓槽行, 逐字符生成鼓点(支持任意步数/切分/三连音/摇摆)
static func _append_drum_pattern(mine: Array, m: AudioMusicDef, pat: DrumPatternDef, bar_off: int, bar_frames: float, intensity: float) -> void:
	var step_frames := bar_frames / maxf(1.0, float(pat.steps))
	for slot in pat.rows.keys():
		if not _drum_slot_in_kit(str(slot), m.drum_kit):
			continue
		var row := str(pat.rows[slot])
		if row.is_empty():
			continue
		for s in pat.steps:
			var ch := row[s % row.length()]
			var vel := _drum_char_velocity(ch)
			if vel <= 0.0:
				continue
			var off := 0.0
			if pat.swing > 0.0 and s % 2 == 1:
				off = pat.swing * step_frames
			mine.append({
				"voice_index": m.voice_index,
				"start": int(bar_off + s * step_frames + off),
				"duration": int(step_frames * 0.8),
				"midi": 0,
				"velocity": vel * intensity,
			})

## 该鼓槽是否属于当前 drum_kit 声部(用于多声部分轨)
static func _drum_slot_in_kit(slot: String, kit: int) -> bool:
	match slot:
		"KICK":
			return kit in [AudioMusicDef.DrumKit.FULL, AudioMusicDef.DrumKit.KICK]
		"SNARE":
			return kit in [AudioMusicDef.DrumKit.FULL, AudioMusicDef.DrumKit.SNARE]
		"HAT_CLOSED":
			return kit in [AudioMusicDef.DrumKit.FULL, AudioMusicDef.DrumKit.HAT]
		"HAT_OPEN":
			return kit in [AudioMusicDef.DrumKit.FULL, AudioMusicDef.DrumKit.HAT_OPEN]
		"TOM", "CLAP":
			return kit == AudioMusicDef.DrumKit.FULL
	return false

## 鼓点字符 → 力度
static func _drum_char_velocity(ch: String) -> float:
	match ch:
		"K": return 0.9
		"S": return 0.75
		"H": return 0.3
		"h": return 0.4
		"T": return 0.7
		"C": return 0.6
		"x": return 0.15
	return 0.0

static func _ev(voice_index: int, start: int, duration: int, midi: int, velocity: float) -> Dictionary:
	# 上限放宽到 2: 段落 intensity>1 可增强力度(合成端直接乘, 母带 soft_clip 收敛)
	return {"voice_index": voice_index, "start": start, "duration": maxi(1, duration), "midi": midi, "velocity": clampf(velocity, 0.0, 2.0)}

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
		AudioMusicDef.ChordType.MAJOR9: return PackedInt32Array([0, 4, 7, 11, 14])
		AudioMusicDef.ChordType.MINOR9: return PackedInt32Array([0, 3, 7, 10, 14])
		AudioMusicDef.ChordType.DOMINANT9: return PackedInt32Array([0, 4, 7, 10, 14])
		AudioMusicDef.ChordType.MAJOR11: return PackedInt32Array([0, 4, 7, 11, 17])
		AudioMusicDef.ChordType.MINOR11: return PackedInt32Array([0, 3, 7, 10, 17])
		AudioMusicDef.ChordType.DOMINANT11: return PackedInt32Array([0, 4, 7, 10, 17])
		AudioMusicDef.ChordType.MAJOR13: return PackedInt32Array([0, 4, 7, 11, 21])
		AudioMusicDef.ChordType.MINOR13: return PackedInt32Array([0, 3, 7, 10, 21])
		AudioMusicDef.ChordType.DOMINANT13: return PackedInt32Array([0, 4, 7, 10, 21])
		AudioMusicDef.ChordType.MAJOR7_SUS4: return PackedInt32Array([0, 5, 7, 11])
		AudioMusicDef.ChordType.SUS2_7: return PackedInt32Array([0, 2, 7, 10])
		AudioMusicDef.ChordType.MAJOR_ADD9: return PackedInt32Array([0, 4, 7, 14])
	return PackedInt32Array([0, 4, 7])