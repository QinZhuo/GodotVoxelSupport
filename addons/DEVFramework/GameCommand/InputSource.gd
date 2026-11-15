@tool
class_name InputSource extends RefCounted

## 决策输入源策略基类（事件驱动轮询模型，回合制与实时通用）。
## ⚠️ 框架只约定"请求描述对象"这一契约，**不感知也不引用任何上层类型**：

## 已消费的答案（按决策顺序）。
var taken: Array[int] = []

## 轮询一次决策，返回答案数组（空数组 = 取消/无法作答）。
func poll(_request: Variant = null) -> Array:
	return []

## 取一次决策的便捷入口（上层统一走它）：返回答案索引，取消/无输入返回 -1，并登记进 taken。
func take(request: Variant = null) -> int:
	var values: Array = await poll(request)
	if values.is_empty():
		return -1
	var value := int(values[0])
	taken.append(value)
	return value

## 一次决策流程结束后，校验"决策段是否被完整消费"。
func verify_consumed() -> String:
	return ""

## 决策答案缺失（take 返回 -1）时，效果层是否可以走"默认目标"兜底：
## 实战交互源 = false（玩家取消就是真取消，不能变成"使用默认目标"）。
func allows_missing_answer() -> bool:
	return false
