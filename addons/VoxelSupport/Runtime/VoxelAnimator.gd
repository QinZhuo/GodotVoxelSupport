class_name VoxelAnimator
extends Node
## 逐帧动画的运行时播放器：按逐帧时长把 `QVoxelAsset` 的一帧帧体素灌进一个 `VoxelData`。
##
## 【它与 VoxelRenderer 的分工】它只改**数据**，一行渲染代码都不写：网格重建是渲染器监听
## `VoxelData.changed` 后的既有职责（而且是块级增量重建）。于是播放代价与"这一帧改了多少块"成正比，
## 不会因为要播动画就每帧重建整个模型。
##
## 【为什么帧数据留在 QVoxelAsset 上，不拷进 VoxelData】一份 .qvx 常被实例化多次（一排士兵、
## 满地金币）。帧数据应当只有一份——`QVoxelAsset` 是 RefCounted，天然可共享；
## 每个实例的 VoxelData 只持有**当前帧**的块缓冲。若把全部帧拷进每个 VoxelData，
## 内存就是"实例数 × 帧数"地涨。
##
## 【用法】
## [codeblock]
## var animator := VoxelAnimator.new()
## add_child(animator)
## animator.setup(asset, data, model_id)   # 默认立刻开始播
## animator.play("walk")                   # 播某个命名区间
## [/codeblock]

## 换帧完成（`index` 为新的帧号）。接它做音效/特效等"跟着帧走"的事。
signal frame_changed(index: int)

## 目标数据资源。为空时 `setup()` 会尝试从自身/父节点的 VoxelRenderer 上取 `data`。
var data: VoxelData

## 帧数据来源（**共享**，不拷贝）。
var asset: QVoxelAsset

## 要播放的模型 id。资产里有多个动画模型时用它选（`setup()` 不传则取第一个）。
var model_id: int = 0

## 时间缩放：1 = 原速，2 = 两倍速，0.5 = 半速。负数会让方向整体倒转。
var speed := 1.0

var _clock := QVoxelFrameClock.new()
var _ready_to_play := false


func _ready() -> void:
	set_process(_ready_to_play and _clock.is_playing())


func _process(delta: float) -> void:
	if _clock.advance(delta * 1000.0 * speed):
		_apply(_clock.index())


# ----------------------------------------------------------------------------
# 装配
# ----------------------------------------------------------------------------

## 装配并（可选）立刻开始播放。返回 false = 该资产在这个 model_id 上没有帧动画，什么都没做。
##
## `mid < 0` 时自动取资产里**第一个**动画模型。`d` 为空时依次尝试：自身节点上的 `data`、
## 父节点若是 `VoxelRenderer` 则取它的 `data`——让"把播放器挂在渲染器下"这种常见摆法不必手写接线。
func setup(a: QVoxelAsset, d: VoxelData = null, mid: int = -1, autoplay: bool = true) -> bool:
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
	_clock.configure(durations, int(anim.get("fps", 12)), bool(anim.get("loop", true)),
			tags if tags is Array else [])

	# 帧 0 必须**无论播不播**都先落到数据上：静态资产摆在那里显示的也应是第 0 帧，
	# 否则"装配了但还没播"的实例会是一片空白，看起来像加载失败。
	_apply(0)
	_ready_to_play = true
	if autoplay:
		play()
	else:
		set_process(false)
	return true


func _find_data() -> VoxelData:
	if get_parent() is VoxelRenderer:
		return (get_parent() as VoxelRenderer).data
	return null


# ----------------------------------------------------------------------------
# 播放控制（全部转发给 QVoxelFrameClock；这份壳只负责"把结果应用出去"）
# ----------------------------------------------------------------------------

## 开始播放。`tag_name` 非空且该标签存在时在它的区间里播（含 reverse / pingpong），否则播整段。
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


## 当前帧在给定原点模式下的位移（`WORLD_ORIGIN` 下恒为零向量）。
##
## 【为什么播放器只报位移、不替调用方搬内容】逐帧重新居中（BOTTOM_CENTER / CONTENT_CENTER）意味着
## 每切一帧都要把每个块**重新切片**——位移一般不是块长的整数倍，跨块的内容得拆到相邻块去，
## 那正是 FRAM 的块级增量想避免的开销。而同一件事做成**节点级平移**既不花一分钱又完全精确。
## 所以这里只给出数字，由调用方（渲染节点）决定要不要用。
## 默认 WORLD_ORIGIN 下恒为零：块表按文件坐标装进去就是最终位置，不需要任何补偿。
func frame_origin_offset(mode: int = VoxelData.OriginMode.WORLD_ORIGIN) -> Vector3:
	if asset == null:
		return Vector3.ZERO
	return asset.origin_offset(mode, _clock.index())


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

## 把第 `k` 帧的块表替换进数据，返回实际改动的块数（0 = 这一帧与上一帧逐块相同）。
## 不播放时也会被 `setup()` / `seek()` 调用，所以这里不碰任何播放态。
func _apply(k: int) -> int:
	if asset == null or data == null:
		return 0
	# 越界帧返回空表（格式层的既定语义，§12.7）时也照样装一遍：表现为"这一帧是空的"。
	# 空表不能跳过 —— 上一帧的块必须被删掉，否则它们会永远留在场景里。
	var changed := data.apply_block_table(asset.frame_blocks(model_id, k))
	frame_changed.emit(k)
	return changed
