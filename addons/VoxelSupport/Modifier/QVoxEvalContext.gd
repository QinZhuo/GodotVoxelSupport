class_name QVoxEvalContext
extends RefCounted
## 求值上下文 —— 算子能看到的全部环境信息都在这里。
##
## 【为什么要有这个对象，而不是给每个算子传一长串参数】后续必然要加字段（halo 窗口、
## 脏区域、分辨率、对象引用、模式开关…）。有了上下文对象，加字段不改变任何算子签名。
## 这正是插件现有契约（PcgDetail.apply(volume, grid_size, seed)）想表达但被固定成三个
## 形参的东西 —— 新代码不该再复制那个形状。

## 本次求值的体积尺寸（体素）。
var grid_size := Vector3i(32, 32, 32)

## 全链共用的主种子（世界级）。逐条修改器的种子由 QVoxModifier.seed 叠加，见 QVoxEvalEngine。
var seed := 0

## 进度回调：Callable(ratio: float)。可为空。
var progress := Callable()

## 取消询问：Callable() -> bool。可为空（视为永不取消）。
var is_cancelled_callable := Callable()

## 本次求值的序号 —— 用于丢弃过期结果（主线程改了对象参数时，在途 worker 的产物作废）。
## 与 PcgModelGenerator._ensure_volume() 的"提交前比对尺寸"是同一思路。
var epoch := 0


static func make(grid_size_: Vector3i, seed_ := 0) -> QVoxEvalContext:
	var ctx := QVoxEvalContext.new()
	ctx.grid_size = grid_size_
	ctx.seed = seed_
	return ctx


## 算子主动查询是否应放弃（长循环里定期调用）。
func cancelled() -> bool:
	if not is_cancelled_callable.is_valid():
		return false
	return bool(is_cancelled_callable.call())


## 算子上报进度。无回调时零开销。
func report(ratio: float) -> void:
	if progress.is_valid():
		progress.call(ratio)
