class_name GoapPlanner extends RefCounted

## GOAP A* 规划器 — 从当前世界状态出发，反向搜索一条代价最小的行动序列，

var max_depth: int = 12

## ===== 计划缓存(跨 agent 共享) =====
static var _cache := {}
static var _cache_hits := 0
static var _cache_misses := 0
const CACHE_MAX_ENTRIES := 512

static func clear_plan_cache() -> void:
	_cache.clear()
	_cache_hits = 0
	_cache_misses = 0

static func plan_cache_stats() -> Dictionary:
	return {"entries": _cache.size(), "hits": _cache_hits, "misses": _cache_misses}

## 带缓存的规划。
func plan_cached(start: GoapWorldState, goal_state: Dictionary, action_defs: Array,
		depth: int = 0, actions_sig := "") -> Array[GoapAction]:
	var key := _cache_key(start, goal_state, action_defs, depth, actions_sig)
	var hit: Variant = _cache.get(key)
	if hit != null:
		_cache_hits += 1
		return _build_plan(hit)
	_cache_misses += 1
	var defs := search_defs(start, goal_state, action_defs, depth)
	if _cache.size() >= CACHE_MAX_ENTRIES:
		_cache.clear()   # 简单上限: 防长会话无限增长
	_cache[key] = defs
	return _build_plan(defs)

func _cache_key(start: GoapWorldState, goal_state: Dictionary, action_defs: Array, depth: int,
		actions_sig := "") -> String:
	var fp := ""
	if start != null and start.has_method("fingerprint"):
		fp = start.fingerprint()
	var sig := actions_sig if actions_sig != "" else actions_signature(action_defs)
	return "%s|%s|%d|%s" % [str(goal_state), fp, depth, sig]

## 行动集的**内容签名**(与对象身份无关, 否则等价行动集会被当成不同 key)。
static func actions_signature(action_defs: Array) -> String:
	var sig := PackedStringArray()
	for d in action_defs:
		sig.append("%s:%.2f:%s:%s" % [d.name, float(d.cost), str(d.preconditions), str(d.effects)])
	return ";".join(sig)

## start      : 当前世界状态
func plan(start: GoapWorldState, goal_state: Dictionary, action_defs: Array, depth: int = 0) -> Array[GoapAction]:
	return _build_plan(search_defs(start, goal_state, action_defs, depth))

## 与 plan() 相同的搜索, 但返回**行动定义序列**(未实例化) —— 供计划缓存复用。
func search_defs(start: GoapWorldState, goal_state: Dictionary, action_defs: Array, depth: int = 0) -> Array:
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
			return node.plan

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
