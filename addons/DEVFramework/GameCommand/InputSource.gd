@tool
class_name InputSource extends RefCounted

## 决策输入源策略基类（tick 轮询模型，回合制与实时通用）。
## 实时游戏每帧/固定间隔轮询一次；回合制在等待操作时反复轮询。
## 模拟层不感知输入来自真实 UI、回放日志还是测试脚本。
## 约定：返回空数组表示本 tick 无输入；取消等操作用显式命令表达（如 &"cancel"）。

## 轮询一次输入。request 携带交互描述（类型/范围/图标等）供实现方渲染或匹配
func poll(_tick: int, _request: Dictionary = {}) -> Array:
	return []
