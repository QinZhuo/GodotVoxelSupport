@tool
## 通用音频管理工具 — 播放 / 总线 / 保存 / 查询 / 效果链 / 编辑器预览与烘焙
## 职责边界:
##   · 通用音频管理(非 PCG 专属): 播放任意 AudioStream / 总线效果 / WAV 保存 / 流信息查询
##   · 程序化**生成**由 Audio 模块承载: Audio/Tool/AudioSynthTool.gd(Def→采样); PCG 经 PCG/Def/AudioGenDef.gd 桥接入管线
##     AudioTool 播放时经 AudioSynthTool 生成, 不承担生成桥接职责
## 使用:
##   AudioTool.play_stream(stream)            # 播放任意音频流(通用)
##   AudioTool.play_loop(def)                 # 程序化 BGM(内部经 AudioSynthTool 生成)
##   AudioTool.setup_audio_buses()            # 标准总线布局
class_name AudioTool

## 标准总线布局资源保存路径(供项目设置引用)
const LAYOUT_PATH := "res://Assets/Audio/AudioBusLayout.tres"
const LAYOUT_SETTING := "audio/buses/default_bus_layout"
## 示例定义目录(AudioTool.example_def / play_example)
const EXAMPLES_DIR := "res://Assets/Def/Audio/Examples/"

## 支持的效果预设名(供 AudioSynthDef.fx_chain / create_fx / fxs_from_names 使用)
static var fx_names := [
	"reverb", "reverb_hall", "delay", "distortion",
	"limiter", "compressor", "eq_lowpass", "eq_highpass", "eq_bandpass", "spectrum",
]

## 波形枚举(与 AudioOscillatorDef.Wave 一致; 配置引用用, 合成在 C++ AudioSynthEngine)
enum Wave {
	## 正弦(纯净圆润)
	SINE,
	## 方波(明亮复古, 8-bit)
	SQUARE,
	## 锯齿(明亮有力)
	SAW,
	## 三角(柔和)
	TRIANGLE,
	## 脉冲(方波+占空比)
	PULSE,
	## 噪声(颗粒/风/爆)
	NOISE,
	## 拨弦(经典 Karplus-Strong 物理建模, 吉他/竖琴/古筝类衰减拨弦音色)
	KARPLUS,
}

## ============ 播放(通用) ============

## 播放已有音频流(自动释放); bus 为空用 Master, fx 非空时自动建 "FX_<bus>" 效果总线
static func play_stream(stream: AudioStream, volume_db := 0.0, bus := "Master", fx: Array[AudioEffect] = []) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.bus = resolve_bus(bus, fx)
	var root := Engine.get_main_loop() as SceneTree
	if root and root.root:
		root.root.add_child(player)
		player.play()
		player.finished.connect(player.queue_free)
	return player

## 生成并立即播放(自动挂到场景树, 播放结束自动释放; 按定义的总线与效果链走 Godot 内置效果)
static func play(def: AudioSynthDef, volume_db := 0.0) -> AudioStreamPlayer:
	var stream := AudioSynthTool.generate(def)
	if stream == null:
		return null
	return play_stream(stream, volume_db, def.bus if def.bus else "Master", def.fx_chain)

## 循环播放 BGM(完整流烘焙后走 Godot 通用 AudioStreamPlayer, 不再实时渲染):
## 后台线程生成完整 loop 音频流(build_stream 自动设 loop_mode), 完成后交给引擎原生播放。
## 返回的 player 立即可用(可 stop/释放); 生成完成前 stream 为空, 完成后自动 play。
## on_ready(player) 可选: 生成完成且已开始播放时回调(可读取 stream 信息)。
## 并发安全: 连续调用只保留最后一次生成的流, 过时生成结果自动丢弃。
static var _loop_token := 0
static func play_loop(def: AudioSynthDef, on_ready: Callable = Callable()) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = resolve_bus(def.bus if def.bus else "Master", def.fx_chain)
	var root := Engine.get_main_loop() as SceneTree
	if root and root.root:
		root.root.add_child(player)
	_loop_token += 1
	@warning_ignore("return_value_discarded")
	_play_loop_async(def, player, _loop_token, on_ready)
	return player

## play_loop 的后台协程: 生成完成后把流挂到播放器并播放; token 不匹配则丢弃(被更新的 play_loop 取代)
static func _play_loop_async(def: AudioSynthDef, player: AudioStreamPlayer, token: int, on_ready: Callable) -> void:
	var stream := await AudioSynthTool.generate_async(def)
	if token != _loop_token:
		return
	if stream != null and is_instance_valid(player):
		player.stream = stream
		player.play()
		if on_ready.is_valid():
			on_ready.call(player)

## 一行播放示例音效(如 AudioTool.play_example("SFX_Laser"))
static func play_example(name: String, volume_db := 0.0) -> AudioStreamPlayer:
	var def := example_def(name)
	if def == null:
		return null
	return play(def, volume_db)

## ============ 编辑器预览(Inspector 按钮使用) ============

## 存储预览状态: 每次调用都生成新 token, 后台生成完成后对比发现 token 变化则丢弃结果(实现取消)
static var _preview_player: AudioStreamPlayer
static var _preview_busy := false
static var _preview_token := 0

## 在编辑器中试听 Def: 先停止旧的, 后台线程生成, 完成后按定义的 bus/fx_chain 播放(loop 的 BGM 自动循环)
## on_ready(result: bool) 可选, 生成播放成功后回调
static func play_editor_preview(def: AudioSynthDef, on_ready: Callable = Callable()) -> void:
	# 先停止旧的(使其 token 失效), 再自增领取新 token — 防止把自己的 token 顶掉
	stop_editor_preview()
	_preview_token += 1
	var token := _preview_token
	_preview_busy = true
	var stream: AudioStreamWAV = await AudioSynthTool.generate_async(def)
	if token != _preview_token:
		return
	_preview_busy = false
	if stream == null:
		if on_ready.is_valid():
			on_ready.call(false)
		return
	_preview_player = play_stream(stream, 0.0, def.bus if def.bus else "Master", def.fx_chain)
	if on_ready.is_valid():
		on_ready.call(true)

## 停止当前编辑器预览(同时使未完成的异步生成结果失效)
static func stop_editor_preview() -> void:
	_preview_token += 1
	_preview_busy = false
	if is_instance_valid(_preview_player):
		_preview_player.stop()
		_preview_player.queue_free()
	_preview_player = null

## 是否在后台生成中
static func is_editor_preview_busy() -> bool:
	return _preview_busy

## 是否正在播放预览中
static func is_editor_preview_playing() -> bool:
	return is_instance_valid(_preview_player) and _preview_player.playing

## ============ 烘焙与效果录音 ============

## 烘焙 Def 为 WAV 文件(异步后台生成 + 标准立体声 WAV 写出): 编辑器按钮一键导出成品音频
## bake_fx=true 时把 def.fx_chain 效果链(内置 AudioEffect)也烘焙进 WAV(经真实播放+录音)
static func bake_wav(def: AudioSynthDef, path: String, bake_fx := true) -> Error:
	stop_editor_preview()
	var stream: AudioStreamWAV = await AudioSynthTool.generate_async(def)
	if stream == null:
		return ERR_CANT_CREATE
	if bake_fx and not def.fx_chain.is_empty():
		var recorded: AudioStreamWAV = await render_with_fx(stream, def.fx_chain)
		if recorded == null:
			LogTool.error("音频", "烘焙失败: 效果录音不可用(需可用音频设备)")
			return ERR_CANT_CREATE
		stream = recorded
	if not path.ends_with(".wav"):
		path += ".wav"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var err := save_wav(stream, path)
	if err == OK:
		LogTool.log("音频", "已烘焙为 WAV: ", path)
		# 编辑器下刷新文件系统使其出现在资源面板(用单例方式取 EditorInterface, 避免编辑器类硬引用)
		if Engine.is_editor_hint():
			var iface := Engine.get_singleton("EditorInterface")
			if iface:
				var fs = iface.get("resource_filesystem")
				if fs:
					fs.call("scan")
	else:
		LogTool.error("音频", "烘焙失败: ", path, " err=", err)
	return err

## 把音频经 fx_chain(内置 AudioEffect 效果链)真实播放一遍并用内置 AudioEffectRecord 录音,
## 返回带效果的音频流。纯内置方案: 效果链与播放时完全一致, 录音截取效果总线输出。
## 注意: 需要可用音频设备(mixer 实时处理); 耗时为音频实时时长 + 0.8s 效果尾音
static func render_with_fx(stream: AudioStreamWAV, fx_chain: Array[AudioEffect]) -> AudioStreamWAV:
	if stream == null or fx_chain.is_empty():
		return stream
	var bus_name := "FX_BakeTemp_" + str(Time.get_ticks_msec())
	var idx := AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(idx, bus_name)
	for fx_effect in fx_chain:
		if fx_effect:
			AudioServer.add_bus_effect(idx, fx_effect)
	var rec := AudioEffectRecord.new()
	AudioServer.add_bus_effect(idx, rec)
	rec.set_recording_active(true)
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = bus_name
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.root.add_child(player)
	player.play()
	# 记录"原始时长 + 效果尾音"(混响/延迟会延伸尾音); 不依赖 finished, 兼容 loop 定义
	var need := stream.get_length() + 0.8
	var elapsed := 0.0
	while elapsed < need:
		await tree.create_timer(0.05).timeout
		elapsed += 0.05
	player.stop()
	if player.get_parent():
		player.queue_free()
	rec.set_recording_active(false)
	var recorded: AudioStreamWAV = rec.get_recording()
	AudioServer.remove_bus(idx)
	return recorded

## ============ 示例快捷访问 ============

## 按名称加载示例定义(DevAudioExamples 生成, 位于 Assets/Def/Audio/Examples/), 不存在返回 null
static func example_def(name: String) -> AudioSynthDef:
	var path := EXAMPLES_DIR + name + ".tres"
	if not ResourceLoader.exists(path):
		LogTool.warn("音频", "示例定义不存在: ", name, " (可用 list_examples 查看)")
		return null
	return load(path)

## 列出全部示例定义名
static func list_examples() -> Array:
	var out: Array = []
	var dir := DirAccess.open(EXAMPLES_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while not f.is_empty():
		if f.ends_with(".tres"):
			out.append(f.trim_suffix(".tres"))
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

## ============ 保存(通用) ============

## 保存为 WAV 文件。
## 注意: 4.7.1 内置 AudioStreamWAV.save_to_wav 会把 16bit 立体声写成 mono 头(数据仍交错),
## 导致 Godot 重新导入后声道/时长错乱, 故这里手写标准 44 字节 PCM 头(立体声/16bit)
static func save_wav(stream: AudioStreamWAV, path: String) -> Error:
	if stream == null or stream.data.is_empty():
		return ERR_INVALID_DATA
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var data := stream.data
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)          # fmt 块长度
	f.store_16(1)           # PCM 编码
	f.store_16(2)           # 声道数: 立体声
	f.store_32(stream.mix_rate)
	f.store_32(stream.mix_rate * 4)  # byte_rate = rate * channels * 2
	f.store_16(4)           # block_align = channels * 2
	f.store_16(16)          # 位深
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()
	return OK

## 保存为 Godot 音频资源(.tres/.res)，供编辑器直接拖入 AudioStreamPlayer
static func save_resource(stream: AudioStream, path: String) -> Error:
	if stream == null:
		return ERR_INVALID_DATA
	return ResourceSaver.save(stream, path)

## 从定义直接保存 WAV（生成 + 写盘一步到位）
static func generate_and_save(def: AudioSynthDef, wav_path: String) -> Error:
	var stream := AudioSynthTool.generate(def)
	if stream == null:
		return ERR_CANT_CREATE
	return save_wav(stream, wav_path)

## ============ 流信息(通用) ============

## 查询音频流信息(时长/采样率/声道/循环), 便于验证生成结果
## 注意: 16bit 数据可直算帧数; 从磁盘导入的 wav 可能是 QOA 压缩(FORMAT_QOA), 无帧数信息
static func get_stream_info(stream: AudioStreamWAV) -> Dictionary:
	if stream == null or stream.data.is_empty():
		return {}
	var info := {
		"mix_rate": stream.mix_rate,
		"channels": 2 if stream.stereo else 1,
		"stereo": stream.stereo,
		"format": stream.format,
		"loop": stream.loop_mode != AudioStreamWAV.LOOP_DISABLED,
		"loop_begin": stream.loop_begin,
		"loop_end": stream.loop_end,
	}
	if stream.format == AudioStreamWAV.FORMAT_16_BITS:
		var bytes_per_frame := 2 if not stream.stereo else 4
		var frame_count := stream.data.size() / bytes_per_frame
		info["frames"] = frame_count
		info["seconds"] = float(frame_count) / stream.mix_rate
	return info

## ============ 总线管理(整合 Godot AudioServer + AudioEffect) ============

## 按名称创建"标准预设"的 Godot 内置效果(AudioEffect), 未知名称返回 null
## 通用参数以本项目 Godot 4.7.1(steam) 实际 API 为准; 需要微调时请直接构造效果并改属性
static func create_fx(name: String) -> AudioEffect:
	match name:
		"reverb":
			var fx := AudioEffectReverb.new()
			fx.room_size = 0.55
			fx.damping = 0.35
			fx.dry = 0.85
			fx.wet = 0.3
			fx.spread = 0.6
			return fx
		"reverb_hall":
			var fx := AudioEffectReverb.new()
			fx.predelay_msec = 20.0
			fx.room_size = 0.95
			fx.damping = 0.45
			fx.dry = 0.6
			fx.wet = 0.5
			fx.spread = 0.9
			return fx
		"delay":
			var fx := AudioEffectDelay.new()
			fx.dry = 1.0
			fx.tap1_active = true
			fx.tap1_delay_ms = 250.0
			fx.tap1_level_db = -10.0
			fx.tap1_pan = -0.3
			fx.feedback_active = true
			fx.feedback_delay_ms = 250.0
			fx.feedback_level_db = -8.0
			fx.feedback_lowpass = 4500.0
			return fx
		"distortion":
			var fx := AudioEffectDistortion.new()
			fx.mode = AudioEffectDistortion.Mode.MODE_CLIP
			fx.pre_gain = 6.0
			fx.drive = 0.35
			fx.post_gain = -4.0
			return fx
		"limiter":
			var fx := AudioEffectLimiter.new()
			fx.threshold_db = -3.0
			fx.ceiling_db = -1.0
			return fx
		"compressor":
			var fx := AudioEffectCompressor.new()
			fx.threshold = -18.0
			fx.ratio = 3.0
			fx.gain = 4.0
			fx.attack_us = 5000
			fx.release_ms = 120.0
			return fx
		"eq_lowpass":
			var fx := AudioEffectLowPassFilter.new()
			fx.cutoff_hz = 4500.0
			fx.resonance = 0.6
			return fx
		"eq_highpass":
			var fx := AudioEffectHighPassFilter.new()
			fx.cutoff_hz = 160.0
			fx.resonance = 0.5
			return fx
		"eq_bandpass":
			var fx := AudioEffectBandPassFilter.new()
			fx.cutoff_hz = 2200.0
			fx.resonance = 1.0
			return fx
		"spectrum":
			return AudioEffectSpectrumAnalyzer.new()
	return null

## 把一组字符串效果名批量转成 AudioEffect 数组(供标准总线布局等 preset 配置使用)
static func fxs_from_names(names: Array) -> Array[AudioEffect]:
	var out: Array[AudioEffect] = []
	for n in names:
		var fx := create_fx(n)
		if fx:
			out.append(fx)
	return out

## 确保总线存在(幂等), 并按要求挂载效果链(原生 AudioEffect 资源数组); 返回总线索引
static func ensure_bus(name: String, fx: Array[AudioEffect] = []) -> int:
	var idx := AudioServer.get_bus_index(name)
	if idx != -1:
		return idx
	idx = AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(idx, name)
	for effect in fx:
		if effect:
			AudioServer.add_bus_effect(idx, effect)
		else:
			LogTool.warn("音频", "未能构建效果, 已跳过: ", effect)
	LogTool.log("音频", "已创建总线: ", name, " 效果数=", fx.size())
	return idx

## 根据需要计算实际播放总线名: 带效果链时自动建 "FX_<bus>" 效果总线
static func resolve_bus(bus: String, fx: Array[AudioEffect]) -> String:
	var name := bus if not bus.is_empty() else "Master"
	if not fx.is_empty():
		name = "FX_" + name
	ensure_bus(name, fx)
	return name

## 一键生成标准总线布局(Master 限幅 / SFX 轻混响+限幅 / BGM 大厅混响+压缩 / UI):
## 1) 立即应用到 AudioServer; 2) 保存为 AudioBusLayout.tres; 3) 写入项目设置
static func setup_audio_buses(apply := true) -> Dictionary:
	var layout := {
		"Master": ["limiter"],
		"SFX": ["reverb", "limiter"],
		"BGM": ["reverb_hall", "compressor"],
		"UI": [],
	}
	if apply:
		# 清空现有总线(保留 0 号 Master)再重建标准布局
		AudioServer.set_bus_count(1)
		while AudioServer.get_bus_effect_count(0) > 0:
			AudioServer.remove_bus_effect(0, 0)
	for name in layout.keys():
		if name != "Master":
			ensure_bus(name, fxs_from_names(layout[name]))
		else:
			for fname in layout[name]:
				var effect := create_fx(fname)
				if effect:
					AudioServer.add_bus_effect(0, effect)
	DirAccess.make_dir_recursive_absolute("res://Assets/Audio")
	var bus_layout := AudioServer.generate_bus_layout()
	var err := ResourceSaver.save(bus_layout, LAYOUT_PATH)
	if err != OK:
		LogTool.error("音频", "保存总线布局失败: ", err)
		return {"ok": false, "error": err}
	ProjectSettings.set_setting(LAYOUT_SETTING, LAYOUT_PATH)
	ProjectSettings.save()
	var buses := {}
	for name in layout.keys():
		buses[name] = AudioServer.get_bus_index(name)
	LogTool.log("音频", "标准总线布局已就绪: ", buses)
	return {"ok": true, "buses": buses, "layout_path": LAYOUT_PATH}
