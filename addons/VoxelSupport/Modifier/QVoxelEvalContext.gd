class_name QVoxelEvalContext
extends RefCounted
## 求值上下文 —— 算子能看到的全部环境信息都在这里。
## 【为什么要有这个对象，而不是给每个算子传一长串参数】后续必然要加字段（halo 窗口、
## 脏区域、分辨率、对象引用、模式开关…）。有了上下文对象，加字段不改变任何算子签名。
## 这正是插件现有契约（PcgDetail.apply(volume, grid_size, seed)）想表达但被固定成三个
## 形参的东西 —— 新代码不该再复制那个形状。

## 本次求值的体积尺寸（体素）。
var grid_size := Vector3i(32, 32, 32)

## 全链共用的主种子（世界级）。逐条修改器的种子由 QVoxelModifier.seed 叠加，见 QVoxelEvalEngine。
var seed := 0

## 进度回调：Callable(ratio: float)。可为空。
var progress := Callable()

## 取消询问：Callable() -> bool。可为空（视为永不取消）。
var is_cancelled_callable := Callable()

## 本次求值的序号 —— 用于丢弃过期结果（主线程改了对象参数时，在途 worker 的产物作废）。
## 与 QVoxelSource._ensure_volume() 的"提交前比对尺寸"是同一思路。
var epoch := 0


static func make(grid_size_: Vector3i, seed_ := 0) -> QVoxelEvalContext:
	var ctx := QVoxelEvalContext.new()
	ctx.grid_size = grid_size_
	ctx.seed = seed_
	return ctx


## 复制一份、只换盒尺寸。盒尺寸相同时直接返回自己（零分配）。
## 【为什么不就地改 grid_size】ctx 由调用方持有，树形求值时同一份 ctx 会喂给**多个**节点；
## 就地改它会让"下一个节点拿到上一个节点的尺寸"这类错误在很远处才爆出来。
## 【为什么复制逻辑住在本类而不是引擎里】它是"本类全部字段的一次列举"；放在字段旁边，
## 将来加字段时改这里就在改字段的同一条视线内。放在引擎里则加一个字段就会静默漏拷，
## 症状是"新字段在树形求值路径下永远是默认值"——极难定位。
func at_grid_size(gs: Vector3i) -> QVoxelEvalContext:
	if grid_size == gs:
		return self
	var c := QVoxelEvalContext.new()
	c.grid_size = gs
	c.seed = seed
	c.progress = progress
	c.is_cancelled_callable = is_cancelled_callable
	c.epoch = epoch
	return c


## 算子主动查询是否应放弃（长循环里定期调用）。
func cancelled() -> bool:
	if not is_cancelled_callable.is_valid():
		return false
	return bool(is_cancelled_callable.call())


## 算子上报进度。无回调时零开销。
func report(ratio: float) -> void:
	if progress.is_valid():
		progress.call(ratio)
