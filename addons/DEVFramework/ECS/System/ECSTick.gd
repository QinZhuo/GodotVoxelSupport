class_name ECSTick
extends Node

## 每帧驱动 ECSWorld 的 Tick 节点。挂到任意场景节点上即可。

var world: ECSWorld

func _process(delta: float) -> void:
	if world != null:
		world.tick(delta)
