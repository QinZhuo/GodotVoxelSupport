class_name QVoxelEvalContext
extends RefCounted
## 求值上下文 —— 算子能看到的全部环境信息都在这里。

## 本次求值的体积尺寸（体素）。
var grid_size := Vector3i(32, 32, 32)

## 主种子（世界级）。
var seed := 0

## 进度回调：Callable(ratio: float)。
var progress := Callable()

## 取消询问：Callable() -> bool。
var is_cancelled_callable := Callable()

## 本次求值的序号 —— 用于丢弃过期结果（主线程改了对象参数时，在途 worker 的产物作废）。
var epoch := 0

static func make(grid_size_: Vector3i, seed_ := 0) -> QVoxelEvalContext:
	var ctx := QVoxelEvalContext.new()
	ctx.grid_size = grid_size_
	ctx.seed = seed_
	return ctx

## 算子主动查询是否应放弃（长循环里定期调用）。
func cancelled() -> bool:
	if not is_cancelled_callable.is_valid():
		return false
	return bool(is_cancelled_callable.call())

## 算子上报进度。
func report(ratio: float) -> void:
	if progress.is_valid():
		progress.call(ratio)
