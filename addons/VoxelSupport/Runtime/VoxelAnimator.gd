class_name VoxelAnimator
extends Node
## 逐帧动画的运行时播放器：按逐帧时长把 `QVoxelAsset` 的一帧帧体素灌进一个 `QVoxelSource`。

## 换帧完成（`index` 为新的帧号）。
signal frame_changed(index: int)

## 目标数据资源。
var data: QVoxelSource

## 帧数据来源（**共享**，不拷贝）。
var asset: QVoxelAsset

## 要播放的模型 id。
var model_id: int = 0

## 时间缩放：1 = 原速，2 = 两倍速，0.5 = 半速。
var speed := 1.0

var _clock := QVoxelFrameClock.new()
var _ready_to_play := false

func _ready() -> void:
	set_process(_ready_to_play and _clock.is_playing())

func _process(delta: float) -> void:
	if _clock.advance(delta * 1000.0 * speed):
		_apply(_clock.index())

# 装配

## 装配并（可选）立刻开始播放。
func setup(a: QVoxelAsset, d: QVoxelSource = null, mid: int = -1, autoplay: bool = true) -> bool:
	stop()
	asset = a
	data = d if d != null else _find_data()
	_ready_to_play = false
	if asset == null or data == null:
		push_warning("[VoxelAnimator] 缺少 asset 或 data，未装配")
		return false
	if mid < 0:
		for id in asset.animations:
			mid = int(id)
			break
	if mid < 0 or not asset.is_animated(mid):
		push_warning("[VoxelAnimator] 资产里没有 model_id=%d 的帧动画" % mid)
		return false
	model_id = mid

	var anim := asset.animation_of(model_id)
	var frames: Array = anim.get("frames", [])
	var durations := PackedInt32Array()
	durations.resize(frames.size())
	for i in frames.size():
		var f: Variant = frames[i]
		durations[i] = int((f as Dictionary).get("duration_ms", 0)) if f is Dictionary else 0
	var tags: Variant = anim.get("tags")
	# 【缺省 fps/loop 必须引用 QVoxelSpec，不能写字面量】编辑器模型 anim_fps 缺省 4，
	_clock.configure(durations,
			int(anim.get("fps", QVoxelSpec.ANIM_FPS_DEFAULT)),
			bool(anim.get("loop", QVoxelSpec.ANIM_LOOP_DEFAULT)),
			tags if tags is Array else [])

	# 帧 0 必须**无论播不播**都先落到数据上：静态资产摆在那里显示的也应是第 0 帧，
	_apply(0)
	_ready_to_play = true
	if autoplay:
		play()
	else:
		set_process(false)
	return true

func _find_data() -> QVoxelSource:
	if get_parent() is VoxelRenderer:
		return (get_parent() as VoxelRenderer).data
	return null

# 播放控制（全部转发给 QVoxelFrameClock；这份壳只负责"把结果应用出去"）

## 开始播放。
func play(tag_name: String = "") -> void:
	if not _ready_to_play:
		return
	_clock.play(tag_name)
	set_process(_clock.is_playing())

func stop() -> void:
	_clock.stop()
	set_process(false)

## 跳到第 `i` 帧并立刻应用（播放中跳 = 从这一帧接着播）。
func seek(i: int) -> void:
	_clock.set_index(i)
	_apply(_clock.index())

func is_playing() -> bool:
	return _clock.is_playing()

## 当前帧号。
func frame() -> int:
	return _clock.index()

## 本模型的总帧数。
func frame_count() -> int:
	return _clock.count()

## 当前生效的标签名（整段播放时为 ""）。
func tag_name() -> String:
	return _clock.tag_name()

# 内部

## 把第 `k` 帧的块表替换进数据，返回实际改动的块数（0 = 这一帧与上一帧逐块相同）。
func _apply(k: int) -> int:
	if asset == null or data == null:
		return 0
	# 越界帧返回空表（格式层的既定语义，§12.7）时也照样装一遍：表现为"这一帧是空的"。
	var changed := data.apply_block_table(asset.frame_blocks(model_id, k))
	frame_changed.emit(k)
	return changed
