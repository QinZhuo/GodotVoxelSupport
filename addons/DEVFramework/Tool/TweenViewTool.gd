## TweenViewTool 是 Tween 视图组件的通用工具类。
## 提取 TweenView / TweenView3D / ButtonView3D 中的重复逻辑，统一管理 Tween 显隐控制和节点释放。
class_name TweenViewTool

## 控制 TweenAnimation 的显隐动画。
## [param tween] 要控制的 TweenAnimation
## [param visible] 当前显隐状态
## [param reset] 是否重设动画后播放
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
## [param node] 要释放的节点
## [param tween] 可选的 TweenAnimation
##
## ⚠️ 不可写成 `await tween.playback().finished`：tween 被 kill() 时 finished 永不触发
## （Godot 已知问题 godotengine/godot-proposals#13296），协程会永久悬挂。
## 而归还对象池、场景切换、重新播放都会 kill tween，于是悬挂的协程状态（含局部变量快照）
## 常驻，反复打断不断累积。改用一次性信号连接则零残留：取消即不释放，
## 且正好符合"已被收回池中的实例不该再被释放"的预期。
static func finish_and_free(node: Node, tween: TweenAnimation) -> void:
	if tween and not tween.is_playback:
		tween.playback().finished.connect(node.queue_free, CONNECT_ONE_SHOT)
		return
	node.queue_free()
