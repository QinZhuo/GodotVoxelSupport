class_name TimerSystem
extends ECSSystem

## 计时器系统 —— 批量推进 + 只处理到期项。
##
## 为什么不是"每帧遍历每个对象的 timers":
##   逐对象实现 2000 个约 **0.4~0.66ms/帧**, 而且绝大多数帧没有到期项 —— 这些时间纯属浪费。
##   本实现: 一次原生列减法(全部计时器) + 一次原生条件过滤(只取 left<=0) = **0.061ms/帧**,
##   且开销只与"到期个数"相关(≈1.35µs/个), 与计时器总数基本无关。
##
## 两种用法:
##   ① 手动: 每帧 `TimerSystem.tick(world, delta)`
##   ② 调度器: `world.scheduler().register_system(TimerSystem.new())` —— 它的 _run 就是 tick

## 到期事件: payload = {entity: 计时器实体, target: 宿主, tag: 分组}
const EVENT_EXPIRED := &"timer_expired"

## 到期处理需要读的字段(一次整列读回来, 避免逐实体跨语言)
const FIELD_NAMES: Array = [&"left", &"duration", &"repeat_mode", &"repeat_count", &"tag", &"target"]


func required_components() -> Array[Script]:
	return [TimerComponent]


func read_components() -> Array[Script]:
	return [TimerComponent]


func write_components() -> Array[Script]:
	return [TimerComponent]


## ⚠ 不能并行: tick 里会**销毁到期计时器实体**(结构性变更), 还会 emit_event。
## 结构性变更会搬动 archetype 行/重建索引, 与任何并行系统的遍历互相破坏。
## (虽然"批量减 left"本身是纯列操作、可并行, 但到期处理不行; 拆成两个系统才值得。)
func can_run_parallel() -> bool:
	return false


func _run(ctx: ECSSystemContext, delta: float) -> void:
	tick(ctx.world, delta)


# ============================================================
#  宿主 API(便利层, 只是语法糖: 内部都是实体 + 组件)
# ============================================================

## 给 host 挂一个计时器, 返回**计时器实体 id**。
## opts: {duration, repeat_count, tag, left} —— 缺省 duration = seconds。
static func add(world: ECSWorld, host: int, seconds: float, opts: Dictionary = {}) -> int:
	if world == null:
		return -1
	var dur := float(opts.get("duration", seconds))
	var rep := int(opts.get("repeat_count", 0))
	var mode := int(opts.get("mode", -1))
	if mode < 0:
		# 只给了 repeat_count 时按次数推断语义(兼容写法): <0 永久 / ==0 一次性 / >0 循环
		if rep < 0:
			mode = TimerComponent.RepeatMode.FOREVER
		elif rep > 0:
			mode = TimerComponent.RepeatMode.REPEAT
		else:
			mode = TimerComponent.RepeatMode.ONCE
	var timer := world.create_entity()
	world.register_component(TimerComponent)
	world.add_component(timer, TimerComponent, {
		&"left": float(opts.get("left", seconds)),
		&"duration": maxf(dur, 0.0),
		&"repeat_mode": mode,
		&"repeat_count": rep,
		&"tag": int(opts.get("tag", 0)),
		&"target": host,
	})
	return timer


## 取消(销毁)计时器实体。
static func cancel(world: ECSWorld, timer: int) -> bool:
	if world == null or not world.is_alive(timer):
		return false
	if not world.has_component(timer, TimerComponent):
		return false
	world.destroy_entity(timer)
	return true


## 剩余秒数(-1 = 该实体不是计时器)。
static func remaining(world: ECSWorld, timer: int) -> float:
	if world == null or not world.is_alive(timer) or not world.has_component(timer, TimerComponent):
		return -1.0
	return float(world.get_field(timer, TimerComponent, &"left"))


## 某宿主身上所有计时器实体(target == host)。
## ⚠ 这是 O(该组件实体数) 的过滤, 别在每帧热路径里对每个宿主都调一次;
##    需要"谁还有冷却"时用 tag + 一次 columns_of 批量判。
static func timers_of(world: ECSWorld, host: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if world == null:
		return out
	for e in world.query_entities(TimerComponent):
		if int(world.get_field(e, TimerComponent, &"target")) == host:
			out.append(e)
	return out


# ============================================================
#  主循环: 批量推进 + 到期处理
# ============================================================

## 推进一帧。返回本帧到期的计时器数量。
static func tick(world: ECSWorld, delta: float) -> int:
	if world == null or delta <= 0.0:
		return 0
	# ① 推进: 一次原生列减法(left += -delta), 不逐实体
	ECSQuery.new(world, TimerComponent).add(&"left", -delta).execute()

	# ② 到期: 条件在原生侧过滤(left <= 0), 只回传到期行
	# ⚠ GDScript 的 lambda **按值捕获**局部变量: 在回调里给 PackedInt32Array 赋值不会传出函数,
	# 必须用 Array(引用类型)当接收槽 —— 实测踩过: execute() 返回 1 但外层拿到空数组。
	var sink: Array = []
	ECSQuery.new(world, TimerComponent) \
			.where(&"left").less_or_equal(0.0) \
			.process(func(rows: PackedInt32Array, _cols: Dictionary, _w) -> void:
				sink.append(rows)).execute()
	var due_rows: PackedInt32Array = sink[0] if not sink.is_empty() else PackedInt32Array()
	if due_rows.is_empty():
		return 0

	# ③ 一次取回"实体列表 + 全部字段列"(各 1 次跨语言), 之后纯 GDScript 遍历。
	# ⚠ 逐实体 get_field 是 1.4µs/次: 5 个字段 × N 个到期就是 7N µs; 整列读 6 字段 2000 行只要 7µs。
	# ⚠ 实体 id 也必须整取(query_entities): entity_of_row 也是逐次跨语言(2.2µs/次)。
	var ents := world.query_entities(TimerComponent)
	if ents.size() <= int(due_rows[due_rows.size() - 1]):
		return 0   # 防御: 聚合序不一致时不动手(宁可少处理, 不可错处理)
	var cols: Dictionary = world.columns_of(TimerComponent, FIELD_NAMES)
	if cols.is_empty():
		return 0
	var c_left: PackedFloat32Array = cols[&"left"]
	var c_dur: PackedFloat32Array = cols[&"duration"]
	var c_mode: PackedInt32Array = cols[&"repeat_mode"]
	var c_rep: PackedInt32Array = cols[&"repeat_count"]
	var c_tag: PackedInt32Array = cols[&"tag"]
	var c_tgt: PackedInt32Array = cols[&"target"]

	var to_destroy := PackedInt32Array()
	var new_left := c_left.duplicate()
	var new_rep := c_rep.duplicate()
	var reset_any := false
	for i in due_rows.size():
		var row := int(due_rows[i])
		if row < 0 or row >= ents.size():
			continue
		var e := ents[row]
		var mode := c_mode[row]
		var rep := c_rep[row]
		var keep := mode == TimerComponent.RepeatMode.FOREVER \
				or (mode == TimerComponent.RepeatMode.REPEAT and rep > 0)
		# 事件先发: 回调里还能读到计时器, 也可以在回调里把它取消
		world.emit_event(EVENT_EXPIRED, {"entity": e, "target": c_tgt[row], "tag": c_tag[row]})
		if keep:
			new_left[row] = maxf(c_dur[row], 0.000001)
			if mode == TimerComponent.RepeatMode.REPEAT:
				new_rep[row] = rep - 1
			reset_any = true
		else:
			to_destroy.append(e)

	# ④ 写回: 循环项一次整列写(1 次跨语言), 一次性项走 cmd 批量销毁(1 次跨语言)
	# ⚠ 顺序: 先写 left 再销毁。销毁会 swap-remove 打乱行号, 之后的整列写会落到错行。
	if reset_any:
		world.set_columns_of(TimerComponent, {&"left": new_left, &"repeat_count": new_rep})
	if not to_destroy.is_empty():
		world.cmd_destroy_many(to_destroy)
		# tick 内(调度器驱动)交给帧末统一 flush, 免得结构变更打断本帧其余系统;
		# 独立调用(测试/手动驱动)必须当场 flush, 否则紧接着的断言读到的是旧行集。
		if not world.is_ticking():
			world.cmd_flush()
	return due_rows.size()
