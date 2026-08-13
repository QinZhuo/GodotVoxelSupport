class_name PCGContext extends RefCounted
## PCG 生成上下文 — 生成管线的数据中转站

## 管线基础种子
var seed := 0
## 当前生成器的随机源（由管线派生，同一 seed 必可复现）
var rng := RandomNumberGenerator.new()
## 生成结果：key → GeneratedGrid / PackedVector2Array / Array
var output: Dictionary = {}

func has(key: String) -> bool:
	return output.has(key)

func get_result(key: String):
	return output.get(key)
