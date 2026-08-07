class_name GoapPlanner extends RefCounted

## GOAP A* 规划器 — 从当前世界状态出发，反向搜索一条代价最小的行动序列，
## 使得执行后满足目标状态。返回按执行顺序排列的 GoapAction 数组。
## 规划失败（无可行方案）返回空数组。

var max_depth: int = 12


## start      : 当前世界状态
## goal_state : 目标状态（键值对字典）
## action_defs: 候选行动定义数组（Array[GoapActionDef]）
## depth      : 搜索深度限制（<=0 使用 max_depth）
func plan(start: GoapWorldState, goal_state: Dictionary, action_defs: Array, depth: int = 0) -> Array[GoapAction]:
	var limit := max_depth if depth <= 0 else depth
	if goal_state.is_empty() or action_defs.is_empty():
		return []
	if start.matches(goal_state):
		return []

	var frontier := _MinHeap.new()
	var explored := {} # 状态指纹 -> 已探索的最优代价
	frontier.push(_SearchNode.new(goal_state.duplicate(), [], 0.0, 0), _heuristic(start, goal_state))

	while not frontier.is_empty():
		var node: _SearchNode = frontier.pop()
		if node.depth >= limit:
			continue
		if start.matches(node.state):
			return _build_plan(node.plan)

		var fingerprint := _state_key(node.state)
		if explored.has(fingerprint) and explored[fingerprint] <= node.cost:
			continue
		explored[fingerprint] = node.cost

		for action_def in action_defs:
			if not _can_satisfy(action_def, node.state):
				continue
			var next_state := node.state.duplicate()
			# 该行动能"产出"的需求键从需求中移除
			for key in action_def.effects:
				if node.state.has(key) and node.state[key] == action_def.effects[key]:
					next_state.erase(key)
			# 需求替换为该行动的前提
			for key in action_def.preconditions:
				next_state[key] = action_def.preconditions[key]

			var next_node := _SearchNode.new(
				next_state,
				[action_def] + node.plan, # 越早选择的行动越靠前执行
				node.cost + action_def.cost,
				node.depth + 1
			)
			frontier.push(next_node, next_node.cost + _heuristic(start, next_state))

	return []


## action 的效果是否满足 node 需求中的至少一项
func _can_satisfy(action_def: GoapActionDef, required: Dictionary) -> bool:
	for key in required:
		if action_def.effects.has(key) and action_def.effects[key] == required[key]:
			return true
	return false


## 启发函数：需求中尚未被当前世界状态满足的键的数量
func _heuristic(start: GoapWorldState, required: Dictionary) -> float:
	var h := 0.0
	for key in required:
		if not start.has_value(key, required[key]):
			h += 1.0
	return h


## 状态指纹：键按字符串排序后拼接，用于去重
func _state_key(state: Dictionary) -> String:
	var keys := state.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	var parts: Array[String] = []
	for key in keys:
		parts.append("%s=%s" % [str(key), str(state[key])])
	return ",".join(parts)


## 把行动定义实例化为行动实体
func _build_plan(action_defs: Array) -> Array[GoapAction]:
	var plan: Array[GoapAction] = []
	for action_def in action_defs:
		plan.append(action_def.create_entity())
	return plan


## —— 内部数据结构 ——

class _SearchNode:
	var state: Dictionary
	var plan: Array      # Array[GoapActionDef]，按执行顺序
	var cost: float
	var depth: int

	func _init(p_state: Dictionary, p_plan: Array, p_cost: float, p_depth: int) -> void:
		state = p_state
		plan = p_plan
		cost = p_cost
		depth = p_depth


## 简易二叉最小堆（按 priority 排序，平局取先入者）
class _MinHeap:
	var _items: Array = []   # [priority, _SearchNode]

	func push(node: _SearchNode, priority: float) -> void:
		_items.append([priority, node])
		var i := _items.size() - 1
		while i > 0:
			var parent := (i - 1) >> 1
			if _items[parent][0] <= _items[i][0]:
				break
			_swap(parent, i)
			i = parent

	func pop() -> _SearchNode:
		var top = _items[0][1]
		var last: Array = _items.pop_back()
		if not _items.is_empty():
			_items[0] = last
			var i := 0
			var size := _items.size()
			while true:
				var left := i * 2 + 1
				var right := i * 2 + 2
				var smallest := i
				if left < size and _items[left][0] < _items[smallest][0]:
					smallest = left
				if right < size and _items[right][0] < _items[smallest][0]:
					smallest = right
				if smallest == i:
					break
				_swap(i, smallest)
				i = smallest
		return top

	func is_empty() -> bool:
		return _items.is_empty()

	func _swap(a: int, b: int) -> void:
		var tmp = _items[a]
		_items[a] = _items[b]
		_items[b] = tmp
