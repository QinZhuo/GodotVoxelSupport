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

## 等待 Tween 动画结束并释放节点。
## 编辑器模式下直接 queue_free 跳过动画。
## [param node] 要释放的节点
## [param tween] 可选的 TweenAnimation
static func finish_and_free(node: Node, tween: TweenAnimation) -> void:
	if tween and not tween.is_playback:
		await tween.playback().finished
	node.queue_free()
