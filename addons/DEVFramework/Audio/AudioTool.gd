@tool
## 运行时音频入口 —— 播放(2D/3D 同接口) + 背景音乐交叉淡化 + 总线音量/静音。
class_name AudioTool

## 每条通道的同时发声上限(远超实际密度, 极端叠加时多出的新声音被引擎丢弃)
const POLYPHONY := 64
## 待播队列上限(树迟迟未就绪时丢弃最旧请求, 避免无界增长)
const PENDING_LIMIT := 64
## 常驻容器节点名(挂在 SceneTree.root 下, 跨场景存活)
const ROOT_NAME := "_Audio"
## 3D 通道节点名(挂在目标 Node3D 下, 随目标销毁)
const TARGET_CHANNEL := "_audio_channel_3d"
## 音乐交叉淡化的电平跨度(dB): 新曲从 -跨度 淡入, 旧曲淡出到 -跨度
const MUSIC_FADE_DB := 40.0

## bus -> 复音通道(AudioStreamPlayer)
static var _channels: Dictionary = {}
static var _root: Node
static var _music: AudioStreamPlayer
## 场景树未就绪时的待播请求(音效队列 + 最近一次音乐请求)
static var _pending: Array[Dictionary] = []
static var _pending_music: Dictionary = {}
static var _flush_connected := false


# ============================================================

## 播放音频流。返回是否已受理(树未就绪时会排队, 就绪后补播, 同样算受理)。
static func play(stream: AudioStream, opts := {}) -> bool:
	if stream == null:
		return false
	if not _tree_ready():
		if _pending.size() >= PENDING_LIMIT:
			_pending.remove_at(0)
		_pending.append({"stream": stream, "opts": opts.duplicate()})
		_connect_flush()
		return true
	return _play_now(stream, opts)


## 停止播放: bus 为空=清空所有 2D 通道; 3D 通道随目标节点销毁, 不在此列
static func stop_all(bus := "") -> void:
	for key: String in _channels.keys():
		if bus.is_empty() or key == bus:
			var player: AudioStreamPlayer = _channels[key]
			if is_instance_valid(player):
				player.stop()


# ============================================================

## 播放背景音乐(单通道, 与旧曲交叉淡化; 同一 stream 重复调用忽略)。stream 为空=停止。
static func play_music(stream: AudioStream, opts := {}) -> void:
	var db := VariantTool.get_float(opts, "volume_db", 0.0)
	var fade := VariantTool.get_float(opts, "fade", 0.5)
	if stream == null:
		stop_music(fade)
		return
	if is_instance_valid(_music) and _music.stream == stream:
		return
	if not _tree_ready():
		_pending_music = {"stream": stream, "opts": opts.duplicate()}
		_connect_flush()
		return
	_fade_out_music(db, fade)
	var root := _channel_root()
	if root == null:
		return
	_music = AudioStreamPlayer.new()
	_music.name = "music"
	_music.stream = stream
	_music.bus = VariantTool.get_string(opts, "bus", "Music")
	_music.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(_music)
	_music.volume_db = db - MUSIC_FADE_DB if fade > 0.0 else db
	_music.play()
	if fade > 0.0:
		var tw := _music.create_tween()
		tw.tween_property(_music, "volume_db", db, fade)


## 停止背景音乐(fade>0 时淡出后释放; 正在淡出的旧曲不受影响)
static func stop_music(fade := 0.0) -> void:
	_fade_out_music(_music.volume_db if is_instance_valid(_music) else 0.0, fade)


## 停掉音乐与全部总线通道、清空待播队列（切场景 / 回标题）。常驻容器保留。
static func reset() -> void:
	stop_music(0.0)
	stop_all()
	_pending.clear()
	_pending_music = {}


# ============================================================

## 设置总线音量(dB); 总线不存在时忽略
static func set_bus_volume(bus: String, db: float) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, db)


## 读取总线音量(dB); 总线不存在返回 0
static func get_bus_volume(bus: String) -> float:
	var idx := AudioServer.get_bus_index(bus)
	return AudioServer.get_bus_volume_db(idx) if idx >= 0 else 0.0


## 静音/取消静音总线; 总线不存在时忽略
static func set_bus_mute(bus: String, muted: bool) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx >= 0:
		AudioServer.set_bus_mute(idx, muted)


# ============================================================

static func _play_now(stream: AudioStream, opts: Dictionary) -> bool:
	var pitch := VariantTool.get_float(opts, "pitch", 1.0)
	var jitter := VariantTool.get_float(opts, "jitter", 0.0)
	if jitter > 0.0:
		pitch *= 1.0 + randf_range(-jitter, jitter) / 1200.0
	var player := _player_for(opts)
	if player == null:
		return false
	var playback := _playback(player)
	if playback == null:
		return false
	return playback.play_stream(stream, 0.0, VariantTool.get_float(opts, "volume_db", 0.0), pitch, 0, "") >= 0


## 取播放节点: 有有效 3D 目标用挂在目标下的定位通道, 否则用该总线的 2D 通道
static func _player_for(opts: Dictionary) -> Node:
	var target: Variant = opts.get("target")
	var bus := VariantTool.get_string(opts, "bus", "Master")
	if target is Node3D and is_instance_valid(target) and (target as Node3D).is_inside_tree():
		return _target_channel(target as Node3D, bus, opts)
	return _channel(bus)


static func _target_channel(target: Node3D, bus: String, opts: Dictionary) -> AudioStreamPlayer3D:
	var player := target.get_node_or_null(TARGET_CHANNEL) as AudioStreamPlayer3D
	if player == null:
		player = AudioStreamPlayer3D.new()
		player.name = TARGET_CHANNEL
		player.stream = _polyphonic()
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		target.add_child(player)
	player.bus = bus
	player.unit_size = VariantTool.get_float(opts, "unit_size", player.unit_size)
	player.attenuation_model = VariantTool.get_int(opts, "attenuation_model", player.attenuation_model)
	return player


static func _channel(bus: String) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = _channels.get(bus)
	if is_instance_valid(player) and player.is_inside_tree():
		return player
	var root := _channel_root()
	if root == null:
		return null
	player = AudioStreamPlayer.new()
	player.name = "channel_" + bus
	player.stream = _polyphonic()
	player.bus = bus
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(player)
	_channels[bus] = player
	return player


## 常驻容器: 跨场景存活, 且不受暂停影响(暂停时 UI/结算音效照常)
static func _channel_root() -> Node:
	if is_instance_valid(_root) and _root.is_inside_tree():
		return _root
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null or not tree.root.is_node_ready():
		return null
	_root = Node.new()
	_root.name = ROOT_NAME
	_root.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child(_root)
	return _root


static func _polyphonic() -> AudioStreamPolyphonic:
	var stream := AudioStreamPolyphonic.new()
	stream.set_polyphony(POLYPHONY)
	return stream


## 复音播放实例: 通道空闲时(无声音)会停止播放, 需先 play 再取
static func _playback(player: Node) -> AudioStreamPlaybackPolyphonic:
	if not _is_playing(player):
		if player is AudioStreamPlayer:
			(player as AudioStreamPlayer).play()
		else:
			(player as AudioStreamPlayer3D).play()
	return player.get_stream_playback() as AudioStreamPlaybackPolyphonic


static func _is_playing(player: Node) -> bool:
	if player is AudioStreamPlayer:
		return (player as AudioStreamPlayer).playing
	if player is AudioStreamPlayer3D:
		return (player as AudioStreamPlayer3D).playing
	return false


static func _fade_out_music(base_db: float, fade: float) -> void:
	if not is_instance_valid(_music):
		return
	var old := _music
	_music = null
	# 淡出中的旧曲先改名, 让新曲继续用 "music"(否则新节点会因重名被引擎自动命名)
	old.name = "music_out"
	if fade <= 0.0:
		old.stop()
		old.queue_free()
		return
	var tw := old.create_tween()
	tw.tween_property(old, "volume_db", base_db - MUSIC_FADE_DB, fade)
	tw.tween_callback(func() -> void:
		old.stop()
		old.queue_free()
	)


# ============================================================

## SceneTree.root 已就绪(可安全 add_child 通道)
static func _tree_ready() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	return tree != null and tree.root != null and tree.root.is_node_ready()


static func _connect_flush() -> void:
	if _flush_connected:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	_flush_connected = true
	if tree.root.is_node_ready():
		_flush.call_deferred()
	else:
		tree.root.ready.connect(_flush, CONNECT_ONE_SHOT)


static func _flush() -> void:
	_flush_connected = false
	if not _tree_ready():
		_connect_flush()
		return
	var pending := _pending.duplicate()
	_pending.clear()
	for req: Dictionary in pending:
		_play_now(req.stream, req.opts)
	if not _pending_music.is_empty():
		var music := _pending_music
		_pending_music = {}
		play_music(music.stream, music.opts)
