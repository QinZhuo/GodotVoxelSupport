## TweenViewTool 是 Tween 视图组件的通用工具类。
class_name TweenViewTool

## 控制 TweenAnimation 的显隐动画。
static func update_visible(tween: TweenAnimation, visible: bool, reset: bool):
	if not tween:
		return
	if visible:
		if reset:
			tween.play_reset()
		else:
			tween.play()
	else:
		tween.playback()

## 播放退出动画，播完后释放节点。
## ⚠️ 不可写成 `await tween.playback().finished`：tween 被 kill() 时 finished 永不触发
static func finish_and_free(node: Node, tween: TweenAnimation) -> void:
	if tween and not tween.is_playback:
		tween.playback().finished.connect(node.queue_free, CONNECT_ONE_SHOT)
		return
	node.queue_free()
