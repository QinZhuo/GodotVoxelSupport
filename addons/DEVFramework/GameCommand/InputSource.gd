@tool
class_name InputSource extends RefCounted

## 决策输入源策略基类（事件驱动轮询模型，回合制与实时通用）。
## 调用方在需要决策时反复调用 poll（实时游戏可每帧调用）；时序不是本接口的事 ——
## 需要时序的场合由上层放进 request 或自行记录，框架不塞无关参数。
## 约定：返回空数组表示本次无输入（=取消/无法作答）。
##
## ⚠️ 框架只约定"请求描述对象"这一契约，**不感知也不引用任何上层类型**：
## request 由上层自由定义（如「选择请求」：选行/选符号/选邻格），
## 框架只原样透传给实现方，由实现方决定如何呈现或匹配。

## 已消费的答案（按决策顺序）。
## 由 [method take] 统一登记；上层可用它把一次操作的决策段回写进命令记录。
var taken: Array[int] = []

## 轮询一次决策，返回答案数组（空数组 = 取消/无法作答）。
## request 为上层定义的交互描述对象（可为空）；本方法不登记 taken。
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
## 返回空串 = 正常；非空 = 问题描述 —— **由调用方决定如何上报**（框架不产出日志、不感知上层）。
## 默认无约束：实战输入源由 UI 事件驱动，不存在"预录答案多/少"这回事。
## 覆写者：[ReplayInputSource]（答案多于实际请求 = 记录与当前效果链不匹配）。
func verify_consumed() -> String:
	return ""

## 决策答案缺失（take 返回 -1）时，效果层是否可以走"默认目标"兜底：
## 回放源 = true（旧格式记录没有决策段，按效果定义的默认行为复现历史）；
## 实战交互源 = false（玩家取消就是真取消，不能变成"使用默认目标"）。
func allows_missing_answer() -> bool:
	return false
