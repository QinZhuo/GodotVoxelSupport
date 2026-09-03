@tool
## 程序化音频生成工具(PCG 模块) — 从 AudioSynthDef 生成采样数据
## 归属 PCG: 与 TextureGenDef(程序化纹理) 同级的"内容生成"职责
##   Def → AudioSequence(事件展开) → AudioSynthEngine(C++ 逐采样合成) → 母带(int16 立体声)
## 通用播放/总线/保存/查询请用 AudioTool(通用音频管理, 非生成)
## PCG 管线接入: PCG/Def/AudioGenDef.gd(extends PCGGeneratorDef) 包装本工具的渲染
class_name AudioSynthTool

## ======= 生成(Def → 采样数据) =======

## 主渲染器: 把 AudioSynthDef 展开成 int16 交错立体声数据
## 逐采样合成由 C++ AudioSynthEngine 完成(见 gdextension/src/audio_synth.cpp)
## 线程安全: 仅返回纯数据字典(不创建 AudioStreamWAV), 供后台线程使用
static func render_data(def: AudioSynthDef) -> Dictionary:
	var sr := int(def.sample_rate)
	var events: Array = AudioSequence.expand(def)

	var total := int(def.duration * sr) if def.duration > 0.0 else 0
	for e in events:
		total = maxi(total, int(e.start) + int(e.duration))
	# 缓冲一段包络释放尾音
	total += int(0.2 * sr)
	if total <= 0:
		return {"ok": false, "reason": "没有可渲染的音符或时长"}

	var per_voice: Array = []
	for i in def.voices.size():
		per_voice.append([])
	for e in events:
		var vi := int(e.voice_index)
		if vi >= 0 and vi < per_voice.size():
			per_voice[vi].append(e)

	var engine := synth_engine(def, sr)
	if engine == null:
		return {"ok": false, "reason": "AudioSynthEngine 原生库不可用"}
	for vi in def.voices.size():
		engine.set_events(vi, per_voice[vi])
	var frames: PackedVector2Array = engine.render(total)

	# 回声/延迟/混响等后期效果不自研, 由 Godot 内置 AudioEffect 在播放总线上提供(AudioSynthDef.bus + fx_chain)

	# 淡出
	if def.fade_out > 0.0 and not def.loop:
		var fc := int(def.fade_out * sr)
		var start := maxi(0, total - fc)
		for i in range(start, total):
			var t := 1.0 - float(i - start) / maxi(1, fc)
			var minv := clampf(t, 0.0, 1.0)
			frames[i] = Vector2(frames[i].x * minv, frames[i].y * minv)

	# 软削波 + 归一化(先统一到 ~1.0 电平再软削波, 最后乘母带音量)
	var peak := 0.0
	for i in total:
		peak = maxf(peak, absf(frames[i].x))
		peak = maxf(peak, absf(frames[i].y))
	var norm := 0.97 / maxf(peak, 0.000001)
	var drive := def.soft_clip
	var fi := int(def.fade_in * sr)
	var bytes := PackedByteArray()
	bytes.resize(total * 2 * 2)
	for i in total:
		var fade := 1.0
		if fi > 0 and i < fi:
			fade = smoothstep(0.0, 1.0, float(i) / fi)
		var l := soft_clip(frames[i].x * norm, drive) * def.master_volume * fade
		var r := soft_clip(frames[i].y * norm, drive) * def.master_volume * fade
		_write_i16(bytes, i * 4, int(clampf(l, -1.0, 1.0) * 32767.0))
		_write_i16(bytes, i * 4 + 2, int(clampf(r, -1.0, 1.0) * 32767.0))

	return {
		"sample_rate": sr,
		"frames": total,
		"data": bytes,
		"loop": def.loop,
	}

## 构建 C++ 合成引擎(逐采样合成核心)。返回 AudioSynthEngine 实例或 null。
static func synth_engine(def: AudioSynthDef, sr: int) -> Object:
	var native := FrameworkNative.get_native(&"AudioSynthEngine",
		[&"configure", &"set_events", &"render", &"reset_stream", &"get_loop_frames"])
	if native == null:
		return null
	var packed := _voice_params(def)
	native.configure(packed[0], packed[1], sr)
	return native

## 把 AudioSynthDef 的声部参数压成扁平数值数组(C++ 端布局见 audio_synth.h VHEAD/OSC_STRIDE)。
## 返回 [PackedFloat32Array 参数, PackedInt32Array 每声部振荡器数]。
static func _voice_params(def: AudioSynthDef) -> Array:
	var params := PackedFloat32Array()
	var counts := PackedInt32Array()
	for v in def.voices:
		counts.append(v.oscillators.size())
		params.append(float(v.kind))
		params.append(v.volume)
		params.append(v.pan)
		params.append(v.noise_amount)
		params.append(v.vibrato_rate)
		params.append(v.vibrato_depth)
		params.append(v.glide)
		params.append(float(v.drum_type))
		params.append(v.drum_freq)
		params.append(v.drum_tone)
		params.append(v.drum_noise)
		params.append(0.0)  # [11] drum_length 已废弃, 占位保持布局稳定
		var env := v.envelope
		params.append(env.attack if env else 0.005)
		params.append(env.decay if env else 0.1)
		params.append(env.sustain if env else 0.7)
		params.append(env.release if env else 0.2)
		params.append(env.curve if env else 0.0)
		var flt := v.filter
		params.append(1.0 if flt and flt.enabled else 0.0)
		params.append(float(flt.mode) if flt else 0.0)
		params.append(flt.cutoff if flt else 8000.0)
		params.append(flt.resonance if flt else 0.3)
		params.append(flt.cutoff_envelope_amount if flt else 0.0)
		params.append(flt.cutoff_lfo_amount if flt else 0.0)
		params.append(float(v.oscillators.size()))
		# LFO 自动化层
		var lfo := v.lfo
		params.append(1.0 if lfo and lfo.enabled else 0.0)
		params.append(lfo.rate if lfo else 5.0)
		params.append(float(lfo.waveform) if lfo else 0.0)
		params.append(lfo.depth if lfo else 0.5)
		params.append(1.0 if lfo and lfo.mod_cutoff else 0.0)
		params.append(1.0 if lfo and lfo.mod_volume else 0.0)
		params.append(1.0 if lfo and lfo.mod_pan else 0.0)
		params.append(1.0 if lfo and lfo.mod_pitch else 0.0)
		for o in v.oscillators:
			params.append(float(o.waveform))
			params.append(o.level)
			params.append(o.detune_cents)
			params.append(float(o.octave_shift))
			params.append(o.pulse_width)
			params.append(o.phase_offset)
			params.append(o.fm_ratio)
			params.append(o.fm_index)
			params.append(o.ks_damping)
	return [params, counts]

static func _write_i16(bytes: PackedByteArray, off: int, v: int) -> void:
	bytes[off] = v & 0xFF
	bytes[off + 1] = (v >> 8) & 0xFF

## 组条 AudioStreamWAV(须在主线程调用)
static func build_stream(data: Dictionary) -> AudioStreamWAV:
	if data.is_empty() or data.get("err", false):
		return null
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = data.sample_rate
	# render_data 输出 L/R 交错立体声(int16, 每帧 4 字节), 必须标记 stereo 否则被当 mono 播放
	stream.stereo = true
	stream.data = data.data
	if data.get("loop", false):
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = data.frames
	return stream

## 同步渲染(主线程, 短音效合适)
static func render(def: AudioSynthDef) -> AudioStreamWAV:
	return build_stream(render_data(def))

## 同步生成音频流(声成即渲染; 短音效建议用, BGM 建议 generate_async)
static func generate(def: AudioSynthDef) -> AudioStreamWAV:
	return render(def)

## 后台线程生成(不阻塞主线程), await 返回 AudioStreamWAV 或 null
static func generate_async(def: AudioSynthDef) -> AudioStreamWAV:
	var t := LogTool.timer("音频", str("后台生成: ", def))
	var data: Dictionary = await AsyncTool.thread_call(func() -> Dictionary:
		return render_data(def)
	)
	t.stop()
	if data.is_empty() or data.get("err", false):
		LogTool.error("音频", "生成失败: ", def)
		return null
	return build_stream(data)

## ======= 生成 DSP 小函数 =======

## 非线性软削波(tanh)——温和过载，防止爆音并带来温暖感
static func soft_clip(x: float, drive: float) -> float:
	if drive <= 0.0001:
		return x
	return tanh(x * drive)

## MIDI 音高 → 频率
static func midi_to_freq(m: int) -> float:
	return 440.0 * pow(2.0, (m - 69.0) / 12.0)

## ======= 调试与基准 =======

## 定义调试分析: 声部/振荡器/事件/时长/内存/渲染耗时 一键信息, 策划验证配置用
static func inspect_def(def: AudioSynthDef) -> Dictionary:
	var sr := int(def.sample_rate)
	var events: Array = AudioSequence.expand(def)
	var total := int(def.duration * sr) if def.duration > 0.0 else 0
	for e in events:
		total = maxi(total, int(e.start) + int(e.duration))
	var per_voice := []
	for i in def.voices.size():
		per_voice.append(0)
	var osc_total := 0
	for v in def.voices:
		osc_total += v.oscillators.size()
	for e in events:
		var vi := int(e.voice_index)
		if vi >= 0 and vi < per_voice.size():
			per_voice[vi] += 1
	var t := Time.get_ticks_usec()
	var stream := generate(def)
	var render_us := Time.get_ticks_usec() - t
	var stream_info := AudioTool.get_stream_info(stream) if stream else {}
	var info := {
		"category": AudioSynthDef.Category.keys()[def.category],
		"sample_rate": sr,
		"voices": def.voices.size(),
		"oscillators_total": osc_total,
		"events_total": events.size(),
		"events_per_voice": per_voice,
		"loop": def.loop,
		"render_ms": render_us / 1000.0,
		"data_kb": (float(stream.data.size()) / 1024.0) if stream else 0.0,
		"stream": stream_info,
		"duration_s": stream_info.get("seconds", float(total) / sr),
	}
	return info

## 性能基准: 渲染 N 次取平均耗时(ms)。注意 BGM 较大会阻塞主线程, 建议小迭代或用 generate_async
static func benchmark(def: AudioSynthDef, iterations := 3) -> Dictionary:
	var times_ms := []
	for i in iterations:
		var t := Time.get_ticks_usec()
		render_data(def)
		times_ms.append((Time.get_ticks_usec() - t) / 1000.0)
	var avg := 0.0
	for x in times_ms:
		avg += x
	avg /= maxi(1, iterations)
	return {
		"iterations": iterations,
		"times_ms": times_ms,
		"avg_ms": avg,
		"seconds_per_iteration": float(int(def.sample_rate) * (def.duration if def.duration > 0.0 else 4.0)) / float(def.sample_rate),
	}

## ======= 随机生成 / 微调变体(sfxr 灵感, Inspector 按钮用) =======

## 全新随机生成音效定义(保持声部/振荡器结构, 若为空则自动建保底结构, 保证点按钮必有声音)
static func randomize_def(def: AudioSynthDef, seed := 0) -> void:
	var rng := RandomNumberGenerator.new()
	if seed > 0:
		rng.seed = seed
	_ensure_baseline_structure(def)
	_randomize_synth(def, rng, 1.0)
	LogTool.log("音频", "已随机生成: ", def)

## 在现有定义基础上微调变体(小幅扰动参数 / 重置编曲种子), 快速得到"相似但不同"的候选
static func mutate_def(def: AudioSynthDef, seed := 0) -> void:
	var rng := RandomNumberGenerator.new()
	if seed > 0:
		rng.seed = seed
	var amt := 0.15
	_randomize_synth(def, rng, amt)
	# 编曲: 重新掷随机种子让旋律/鼓型变化, 其余参数已在上面微调
	for m in def.music:
		if _locked(def, "music"):
			break
		m.random_seed = rng.randi()
	LogTool.log("音频", "已微调变体: ", def)

## 是否命中参数锁(顶层属性名)
static func _locked(def: AudioSynthDef, prop: String) -> bool:
	for s in def.mutate_locked:
		if s == prop:
			return true
	return false

static func _randf(rng: RandomNumberGenerator, lo: float, hi: float) -> float:
	return rng.randf_range(lo, hi)

## 幅度扰动: v 在当前值附近乘(1±amt)；随机模式(amt>=1)直接用 lo~hi 全范围
static func _perturb(rng: RandomNumberGenerator, v: float, lo: float, hi: float, amt: float) -> float:
	if amt >= 1.0:
		return _randf(rng, lo, hi)
	return clampf(v * _randf(rng, 1.0 - amt, 1.0 + amt), lo, hi)

static func _add(rng: RandomNumberGenerator, v: float, spread: float, lo: float, hi: float, amt: float) -> float:
	if amt >= 1.0:
		return _randf(rng, lo, hi)
	return clampf(v + _randf(rng, -spread * amt, spread * amt), lo, hi)

## 若没有可发声的内容则补默认结构: 1 个正弦音色 + 一段音效式下行音符
static func _ensure_baseline_structure(def: AudioSynthDef) -> void:
	if def.voices.is_empty():
		var v := AudioVoiceDef.new()
		var o := AudioOscillatorDef.new()
		o.waveform = AudioOscillatorDef.Wave.SINE
		v.oscillators = [o]
		v.envelope = AudioEnvelopeDef.new()
		v.envelope.decay = 0.15
		v.envelope.sustain = 0.2
		def.voices.append(v)
	if def.patterns.is_empty() and def.music.is_empty():
		var p := AudioPatternDef.new()
		p.bpm = 320.0
		p.voice_index = 0
		p.notes = [
			_quick_note(72, 0.06), _quick_note(60, 0.08), _quick_note(48, 0.1),
		]
		def.patterns.append(p)

static func _quick_note(midi: int, beats: float) -> AudioNoteDef:
	var n := AudioNoteDef.new()
	n.midi = midi
	n.length_beats = beats
	return n

## 核心: 按 amt(0~1, 1=全范围随机)扰动定义内外参数
static func _randomize_synth(def: AudioSynthDef, rng: RandomNumberGenerator, amt: float) -> void:
	if not _locked(def, "master_volume"):
		def.master_volume = _perturb(rng, def.master_volume, 0.35, 1.0, amt)
	if not _locked(def, "soft_clip"):
		def.soft_clip = _add(rng, def.soft_clip, 0.8, 0.0, 2.0, amt)
	if not _locked(def, "bus"):
		if rng.randf() < 0.15:
			def.bus = ["SFX", "UI"][rng.randi_range(0, 1)]
	for v in def.voices:
		_randomize_voice(v, rng, amt, def.random_preserve_wave)
	if not _locked(def, "bpm"):
		for music in def.music:
			music.bpm = clampf(music.bpm * _randf(rng, 1.0 - 0.12 * amt, 1.0 + 0.12 * amt), 30.0, 320.0)

static func _randomize_voice(v: AudioVoiceDef, rng: RandomNumberGenerator, amt: float, preserve_wave: bool) -> void:
	if v.kind == AudioVoiceDef.Kind.DRUM:
		v.drum_freq = _perturb(rng, v.drum_freq, 40.0, 220.0, amt)
		v.drum_tone = _add(rng, v.drum_tone, 0.25, 0.15, 1.0, amt)
		v.drum_noise = _add(rng, v.drum_noise, 0.3, 0.05, 0.95, amt)
		return
	v.volume = _perturb(rng, v.volume, 0.2, 1.0, amt)
	v.pan = clampf(v.pan + _randf(rng, -0.5 * amt, 0.5 * amt), -1.0, 1.0)
	v.noise_amount = _add(rng, v.noise_amount, 0.3, 0.0, 0.7, amt)
	v.vibrato_rate = _perturb(rng, v.vibrato_rate, 0.0, 12.0, amt)
	v.vibrato_depth = _add(rng, v.vibrato_depth, 0.025, 0.0, 0.08, amt)
	v.glide = _add(rng, v.glide, 0.1, 0.0, 0.35, amt)
	# 包络
	if v.envelope:
		v.envelope.attack = _add(rng, v.envelope.attack, 0.06, 0.0, 0.35, amt)
		v.envelope.decay = _perturb(rng, v.envelope.decay, 0.03, 0.8, amt)
		v.envelope.sustain = _add(rng, v.envelope.sustain, 0.2, 0.0, 0.95, amt)
		v.envelope.release = _perturb(rng, v.envelope.release, 0.02, 0.6, amt)
		v.envelope.curve = _add(rng, v.envelope.curve, 0.4, -0.9, 0.9, amt)
	# 滤波器
	if v.filter and v.filter.enabled:
		v.filter.cutoff = _perturb(rng, v.filter.cutoff, 120.0, 14000.0, amt)
		v.filter.resonance = _add(rng, v.filter.resonance, 0.25, 0.0, 0.9, amt)
		v.filter.cutoff_envelope_amount = _add(rng, v.filter.cutoff_envelope_amount, 3000.0, -8000.0, 8000.0, amt)
	# 振荡器
	for o in v.oscillators:
		if o == null:
			continue
		if not preserve_wave and amt >= 1.0:
			o.waveform = rng.randi_range(0, AudioOscillatorDef.Wave.PULSE)
		o.level = _perturb(rng, o.level, 0.15, 1.0, amt)
		o.detune_cents = _add(rng, o.detune_cents, 30.0, -120.0, 120.0, amt)
		o.pulse_width = _perturb(rng, o.pulse_width, 0.1, 0.9, amt)
