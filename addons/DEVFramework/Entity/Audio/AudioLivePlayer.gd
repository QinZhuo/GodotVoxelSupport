@tool
## 实时程序化 BGM 播放器 — 用 AudioStreamGenerator 逐块渲染，支持无限循环不占内存
## 使用方法：add_child(player); player.setup(def); player.play()
class_name AudioLivePlayer extends AudioStreamPlayer

var synth_def: AudioSynthDef
var _playback: AudioStreamGeneratorPlayback
var _mix_rate := 22050.0
var _voices: Array[AudioVoice] = []
var _loop_frames := 0
var _global_index := 0
var _fade_in_frames := 0
var _fade_done := true
const _BLOCK := 2048

## 使用前必须调用：加载定义并准备好渲染状态
func setup(def: AudioSynthDef) -> void:
	synth_def = def
	_mix_rate = minf(def.sample_rate, 22050.0)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _mix_rate
	gen.buffer_length = 0.4
	stream = gen
	# 播放总线: 带效果链时自动创建 "FX_<bus>" 效果总线并挂载 Godot 内置效果
	bus = AudioTool.resolve_bus(def.bus, def.fx_chain)

	var events: Array = AudioSequence.expand(def)
	var per_voice: Array = []
	for i in def.voices.size():
		per_voice.append([])
	for e in events:
		var vi := int(e.voice_index)
		if vi >= 0 and vi < per_voice.size():
			per_voice[vi].append(e)
	for vi in def.voices.size():
		var v := AudioVoice.new(def.voices[vi], _mix_rate)
		v.events = per_voice[vi]
		_voices.append(v)
	_loop_frames = 0
	for v in _voices:
		_loop_frames = maxi(_loop_frames, v.last_frame())
	if _loop_frames <= 0:
		_loop_frames = int(def.duration * _mix_rate) if def.duration > 0.0 else int(8.0 * _mix_rate)
	_fade_in_frames = int(def.fade_in * _mix_rate)
	_fade_done = def.fade_in <= 0.0

func _ready() -> void:
	if stream:
		play()

func _process(_delta: float) -> void:
	if not _playback:
		_playback = get_stream_playback()
	if _playback == null or _voices.is_empty():
		return
	var available := _playback.get_frames_available()
	while available > 0:
		var n := mini(_BLOCK, available)
		_render_and_push(n)
		available -= n

func _render_and_push(count: int) -> void:
	var l := PackedFloat32Array()
	var r := PackedFloat32Array()
	l.resize(count)
	r.resize(count)
	for vi in _voices.size():
		var vd: AudioVoiceDef = synth_def.voices[vi]
		var mono := _voices[vi].render_to_array(count)
		var pan := clampf(vd.pan, -1.0, 1.0)
		var gl := cos((pan + 1.0) * PI / 4.0) * vd.volume
		var gr := sin((pan + 1.0) * PI / 4.0) * vd.volume
		for i in count:
			l[i] += mono[i] * gl
			r[i] += mono[i] * gr
	_global_index += count
	if _global_index >= _loop_frames:
		_global_index = 0
		for v in _voices:
			v.reset_stream()
	if not _fade_done:
		var g := 1.0
		if _global_index >= _fade_in_frames:
			_fade_done = true
		else:
			g = smoothstep(0.0, 1.0, float(_global_index) / maxf(1.0, float(_fade_in_frames)))
		for i in count:
			_playback.push_frame(Vector2(l[i] * g, r[i] * g))
		return
	for i in count:
		_playback.push_frame(Vector2(l[i], r[i]))