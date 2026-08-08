class_name ECSTick
extends Node

## 每帧驱动 ECSWorld 的 Tick 节点。挂到任意场景节点上即可。
## 用法: ecs_tick.world = world  (代码赋值, RefCounted 不支持 @export)

var world: ECSWorld

func _process(delta: float) -> void:
	if world != null:
		world.tick(delta)
