# Tween 数据驱动补间动画

`TweenAnimation` 用节点树描述一段补间：每个直接子节点是一条 tweener，`play()` 正向、`playback()` 反向，子节点可嵌套形成串行/并行序列。
`TweenView` / `TweenView2D` / `TweenView3D` 把节点显隐接到这套动画上；`TweenViewTool` 负责安全地等待结束与离场释放。

| 类 | 职责 |
|---|---|
| `TweenAnimation` | `play` / `playback` / `play_reset` / `play_loops` / `reset`；`is_playback`、`cur_tween` |
| `TweenValue` | 抽象基类：`from_value`、`final_value`、`duration`、`playback_duration`、`transition_type`、`ease_type` |
| `TweenProperty` | 对 `node` 的 `property`（`set_indexed` 路径）补间；`node` 为空时向上找父节点 |
| `TweenPropertyArray` | 按 `final_values` 均分时长逐段补间，反向时补回 `from_value` |
| `TweenMethod` | 每帧发 `tween_method(value)` 信号 |
| `TweenCallback` / `TweenInterval` | 触发一次 `tween_callback` / 等待 `time` 秒 |
| `TweenShake` | `Noise` + `scale_curve` 逐帧抖动，`offset_value` 即抖动幅度 |
| `TweenView` / `2D` / `3D` | `tween_visible` 控制显隐，`tween_free()` 播离场后释放 |
| `TweenViewTool` | `update_visible`、`await_done`、`finish_and_free` |

```gdscript
@onready var anim: TweenAnimation = $TweenAnimation

func _ready() -> void:
	var fade := TweenProperty.new()
	fade.node = $Panel
	fade.property = "modulate:a"
	fade.from_value = 0.0
	fade.final_value = 1.0
	fade.duration = 0.3
	anim.add_child(fade)
	await TweenViewTool.await_done(self, anim.play())
	await TweenViewTool.await_done(self, anim.playback())

anim.play_reset()      # 先 reset 全部子节点，再从 from_value 播
anim.play_loops(3)     # 循环 3 次；0 = 无限
anim.reset()           # 立即写回所有 from_value，不播动画
```

## 坑

1. **不要 `await tween.play().finished`，要用 `TweenViewTool.await_done(owner, tween)`**：`play()` / `playback()` 会先 `kill()` 上一个 tween，被 kill 的 Tween 永远不发 `finished`，协程会永久挂起。`await_done` 按 `is_running()` 每帧轮询，owner 被释放也会返回。
2. `finish_and_free()` 用 `playback().finished.connect(queue_free, CONNECT_ONE_SHOT)` 而不是 `await`，原因同上；已在播放退场时直接 `queue_free()`。
3. `TweenAnimation` 只处理直接子节点里 `is TweenAnimation` 的节点，其他子节点被忽略。`playback()` 时子节点逆序执行并使用各自的 `playback_duration`，`from_value` / `final_value` 互换。
4. `play()` / `playback()` 内部写死 `set_ignore_time_scale(true)`：不受 `Engine.time_scale` 影响，暂停游戏不等于暂停 tween。
5. `TweenProperty.reset()` 把 `from_value` 写回属性，所以 `from_value` 必须与动画开始前的状态一致，否则 `play_reset()` / `reset()` 会把节点拉回错误值。`TweenPropertyArray` 的 `final_values` 为空时不生成 tween。
6. `TweenView2D/3D` 放进对象池时 `on_pool_return()` 必须杀掉 `cur_tween`（基类已实现）；不杀的话播放完成回调会释放还在池里的节点。
