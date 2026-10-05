@tool
## 通用音频管理工具 — 播放 / 总线 / 保存 / 查询 / 效果链 / 效果录音
## 职责边界: 只做通用音频管理(播放任意 AudioStream / 总线效果 / WAV 保存 / 流信息查询)。
##   程序化音频合成已从本仓移除, 本工具不再承担生成职责。
## 使用:
##   AudioTool.play_stream(stream)            # 播放任意音频流
##   AudioTool.setup_audio_buses()            # 标准总线布局
##   AudioTool.save_wav(stream, path)         # 导出 WAV
class_name AudioTool

## 标准总线布局资源保存路径(供项目设置引用)
const LAYOUT_PATH := "res://Assets/Audio/AudioBusLayout.tres"
const LAYOUT_SETTING := "audio/buses/default_bus_layout"

## 支持的效果预设名(供 create_fx / fxs_from_names / 标准总线布局使用)
static var fx_names := [
	"reverb", "reverb_hall", "delay", "distortion",
	"limiter", "compressor", "eq_lowpass", "eq_highpass", "eq_bandpass", "spectrum",
]

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

## ============ 效果录音(通用) ============

## 把音频经效果链(内置 AudioEffect)真实播放一遍并用内置 AudioEffectRecord 录音,
## 返回带效果的音频流。纯内置方案: 效果链与播放时完全一致, 录音截取效果总线输出。
## 注意: 需要可用音频设备(mixer 实时处理); 耗时为音频实时时长 + 0.8s 效果尾音
static func render_with_fx(stream: AudioStreamWAV, fx_chain: Array[AudioEffect]) -> AudioStreamWAV:
	if stream == null or fx_chain.is_empty():
		return stream
	var bus_name := "FX_RecordTemp_" + str(Time.get_ticks_msec())
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

## ============ 流信息(通用) ============

## 查询音频流信息(时长/采样率/声道/循环)
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
