class_name ECSSystem
extends Def

## ECS 系统基类 —— 用户编写系统逻辑的入口。Def 风格(同项目 Def 体系, 继承 Resource):
## 支持 @export 属性在 Inspector / 场景 / .tres 中配置, 由 World 节点(场景桥接层)实例化并注册。
## 注意: 系统实例的 _run/_schedule 状态在"每世界独立副本"上, 符合 Def"配置 + 副本实例化"约定。
##
## 用法:
##   class_name HealSystem extends ECSSystem:
##       @export var heal_amount: float = 5.0
##       func required_components() -> Array[Script]:
##           return [HealthComponent]
##       func _run(ctx: ECSSystemContext, delta: float) -> void:
##           ctx.for_each(HealthComponent).add(&"hp", heal_amount).execute()
##
## 性能要点:
##   - 高频逻辑优先用规则动作(C++ batch): add/sub/mul/div/add_from/set_from/clamp_where。
##   - 复杂逻辑用 process 回调(预拉列自动写回或对齐行号模式)。
##   - 不要在循环内 get_field/set_field(单实体跨语言调用)。

## 系统执行优先级(同优先级按注册顺序, 数值小先跑; 供场景/代码配置)
@export var priority: int = 0

## 系统启停开关
@export var enabled: bool = true

## —— 频率控制(参考 Flecs interval/rate、Unity RateUtils、Bevy FixedUpdate) ——
## interval:   每隔 interval 秒运行一次(0 = 每帧)。低频系统(AI/UI/网络)用它省 CPU。
## rate:       每 rate 帧运行一次(1 = 每帧)。次高频逻辑按帧率节流。
## fixed_step: 固定步长(秒)。>0 时按固定步长运行: 每帧累积时间, 够一个步长才运行一次,
##             且系统 _run 收到的是 fixed_step(而非帧 delta) → 物理/网络确定性。
##             与 interval/rate 互斥(优先 fixed_step)。
@export var interval := 0.0
@export var rate := 1
@export var fixed_step := 0.0

# 频率累积状态
var _t_acc := 0.0     # interval 时间累积
var _frame_n := 0     # rate 帧计数
var _fix_acc := 0.0   # fixed_step 时间累积
var _frame_delta := -1.0  # 本帧系统应运行的 delta(-1 = 本帧不运行), ECSWorld 调度前设置

## 频率调度(主线程, ECSWorld.tick 开头对每个系统调用一次)。
## 返回本帧系统应使用的 delta; -1 表示本帧不运行。内部更新累积计数。
func _schedule(delta: float) -> float:
	if not enabled:
		_frame_delta = -1.0
		return -1.0
	if fixed_step > 0.0:
		_fix_acc += delta
		if _fix_acc < fixed_step:
			_frame_delta = -1.0
			return -1.0
		_fix_acc -= fixed_step
		_frame_delta = fixed_step
		return fixed_step
	if interval > 0.0:
		_t_acc += delta
		if _t_acc < interval:
			_frame_delta = -1.0
			return -1.0
		_t_acc -= interval
		_frame_delta = delta
		return delta
	_frame_n += 1
	if _frame_n % rate != 0:
		_frame_delta = -1.0
		return -1.0
	_frame_delta = delta
	return delta

## 本系统需要使用的组件类(用于自动注册与查询)
func required_components() -> Array[Script]:
	return []

## 本系统"只读"的组件类。用于依赖图自动推断。
## 默认 = required_components()(假设全部只读), 可覆写以精确声明。
func read_components() -> Array[Script]:
	return required_components()

## 本系统"会写入"的组件类。用于依赖图自动推断。
## 默认 = 空(假设只读), 写入系统请覆写。
## 例: func write_components() -> Array[Script]: return [HealthComponent]
func write_components() -> Array[Script]:
	return []

## 用户实现: 每帧业务逻辑
func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	pass

## 系统被注册到世界后调用一次(初始化钩子)。场景/Inspector 配置的规则可在此应用,
## 需要访问世界时也在此保存引用。默认空实现。
func _on_registered(_world: ECSWorld) -> void:
	pass

## 本系统是否允许与其他系统并行执行(同一帧)。
## 并行前提(必须全部满足, 否则请覆写返回 false):
##   - 不访问场景树/节点/渲染/UI 等主线程独占资源
##   - 不依赖帧内其他系统产生的瞬时状态
##   - read_components()/write_components() 已准确声明全部读写组件
## 框架会按"组件访问集合"自动做冲突检测: 访问同一组件的系统自动串行,
## 互不访问的系统才真正并行 —— 无需在此手动指定谁与谁并行。
## 访问场景树/节点的系统(如 ECSSyncSystem)必须覆写返回 false。
func can_run_parallel() -> bool:
	return true
