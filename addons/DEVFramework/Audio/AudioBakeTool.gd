@tool
## 音频资产烘焙(仅编辑器) —— 经效果链实时录音 + 写标准 WAV。游戏运行时不调用。
class_name AudioBakeTool

## 效果尾音余量(秒): 混响/延迟会延长尾音, 按此额外录一段
const TAIL_SEC := 0.8


## 把音频经效果链真实播放一遍并用 AudioEffectRecord 录回, 返回带效果的流。
static func bake_with_fx(stream: AudioStreamWAV, fx_chain: Array[AudioEffect]) -> AudioStreamWAV:
	if stream == null:
		return null
	if fx_chain.is_empty():
		return stream
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	# 临时总线: 追加在末尾(录制完成后按同一索引删除, 不影响其它总线)
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	for effect: AudioEffect in fx_chain:
		if effect:
			AudioServer.add_bus_effect(idx, effect)
	var recorder := AudioEffectRecord.new()
	AudioServer.add_bus_effect(idx, recorder)
	recorder.set_recording_active(true)
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = AudioServer.get_bus_name(idx)
	tree.root.add_child(player)
	player.play()
	# 不依赖 finished: 兼容循环定义, 按"时长 + 尾音"一次性等待
	await tree.create_timer(stream.get_length() + TAIL_SEC, true, false, true).timeout
	recorder.set_recording_active(false)
	player.stop()
	player.queue_free()
	var recorded := recorder.get_recording()
	AudioServer.remove_bus(idx)
	return recorded


## 写标准 44 字节 PCM WAV(按流的声道/位深推导头部; 蒙版/压缩格式返回错误)。
## 注意: 内置 AudioStreamWAV.save_to_wav 会把 16bit 立体声写成 mono 头, 故这里自行写头。
static func save_wav(stream: AudioStreamWAV, path: String) -> Error:
	if stream == null or stream.data.is_empty():
		return ERR_INVALID_DATA
	var bits := 0
	match stream.format:
		AudioStreamWAV.FORMAT_8_BITS:
			bits = 8
		AudioStreamWAV.FORMAT_16_BITS:
			bits = 16
		_:
			LogTool.error("音频", "仅支持 8/16bit PCM 导出, 当前格式: ", stream.format)
			return ERR_UNAVAILABLE
	var channels := 2 if stream.stereo else 1
	var bytes_per_sample := bits / 8
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer("RIFF".to_ascii_buffer())
	file.store_32(36 + stream.data.size())
	file.store_buffer("WAVEfmt ".to_ascii_buffer())
	file.store_32(16)                                    # fmt 块长度
	file.store_16(1)                                     # PCM 编码
	file.store_16(channels)
	file.store_32(stream.mix_rate)
	file.store_32(stream.mix_rate * channels * bytes_per_sample)  # byte_rate
	file.store_16(channels * bytes_per_sample)           # block_align
	file.store_16(bits)
	file.store_buffer("data".to_ascii_buffer())
	file.store_32(stream.data.size())
	file.store_buffer(stream.data)
	file.close()
	return OK
