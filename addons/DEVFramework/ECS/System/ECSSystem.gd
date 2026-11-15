class_name ECSSystem
extends RefCounted

## ECS 系统运行时基类 —— 逻辑、配置与运行态都在实例上，不依赖 Def 数据管线。

## 优先级（大者先跑，同优先级按注册顺序）；register_system() 不传参时取它
var priority: int = 0

## 启停开关
var enabled: bool = true

## —— 频率控制(参考 Flecs interval/rate、Unity RateUtils、Bevy FixedUpdate) ——
var interval: float = 0.0
var rate: int = 1
var fixed_step: float = 0.0

# 频率累积状态(每实例私有)
var _t_acc := 0.0     # interval 时间累积
var _frame_n := 0     # rate 帧计数
var _fix_acc := 0.0   # fixed_step 时间累积
var _frame_delta := -1.0  # 本帧系统应运行的 delta(-1 = 本帧不运行), ECSWorld 调度前设置


## 系统名(日志/调试用): 脚本全局类名
func get_system_name() -> String:
	var s: Script = get_script()
	return s.get_global_name() if s != null else "?"


## 频率调度(主线程, ECSWorld.tick 开头对每个系统调用一次)。
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
func read_components() -> Array[Script]:
	return required_components()


## 本系统"会写入"的组件类。用于依赖图自动推断。
func write_components() -> Array[Script]:
	return []


## 用户实现: 每帧业务逻辑
func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	pass


## 系统被注册到世界后调用一次(初始化钩子)。需要访问世界时在此保存引用。默认空实现。
func _on_registered(_world: ECSWorld) -> void:
	pass


## 本系统是否允许与其他系统并行执行(同一帧)。
## 并行前提(必须全部满足, 否则请覆写返回 false):
##   - 不访问场景树/节点/渲染/UI 等主线程独占资源
##   - 不依赖帧内其他系统产生的瞬时状态
##   - read_components()/write_components() 已准确声明全部读写组件
func can_run_parallel() -> bool:
	return true
