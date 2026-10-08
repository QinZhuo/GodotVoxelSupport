@tool
class_name QVoxObjectGenerator
extends PcgModelGenerator

## 适配器：把 QVoxObject（手绘体素 + 修改器链）接到 VoxelGenerator（逐 chunk 供数）上。
##
## 【与父类的关系】"整块体积 → 逐 chunk"的缓存、切片、LOD 采样全部继承自 PcgModelGenerator，
## 本类只换掉"体积从哪来"这一件事（覆写 _has_source / _build_volume）。于是这条路径
## 全项目仍只有一份实现 —— 这正是 P3「统一生成流水线」要的结果：不管体积出自
## L-系统、元胞自动机、WFC 还是修改器链，切片侧看到的都是同一个 VoxelGenerator 契约。
##
## 【为什么链不走"边切片边采样"】SDF 逐点采样天生适合按 chunk 懒算，但**细节层需要完整邻域**：
## 风化判定暴露面、染色挑色阶都要看邻居，按 chunk 各算各的会在 chunk 边界留下接缝
## （PcgSdfGenerator 过去正是绕开这一点，代价是岛体没有任何表面层次）。
## 故链一律"先生成完整体积，再进链"——代价是有界模型要常驻一份体积，
## 这正是 P2/P3 的取舍：有限内核换掉无限流式（见 docs/REFACTOR_PLAN.md §4）。
##
## 【用法】
##   var gen := QVoxObjectGenerator.new()
##   gen.object = my_qvox_object      # 手绘体素 + 修改器链（SDF 生产 → 风化 → 染色）
##   gen.eval_seed = 20261007
##   var data := VoxelData.new(); data.generator = gen; data.grid_size = obj.grid_size
##
## 【增量复用】上一次的求值结果留在 _last 里：主线程只调了一次参数、什么都没变时，
## 下一次求值（例如改一条修改器后按 chunk 重建）由引擎的签名比对直接返回旧结果，
## 一次遍历都不做。改动链之后调用 invalidate() 即可，签名比对负责判断是否真的要重算。

## 要渲染的对象（手绘体素 + 修改器链）。
@export var object: QVoxObject:
	set(value):
		if object == value:
			return
		object = value
		_invalidate()


## 求值种子（透传给 QVoxEvalContext.seed，是全链共用的主种子）。
@export var eval_seed: int = 0:
	set(value):
		if eval_seed == value:
			return
		eval_seed = value
		_invalidate()


## 对象的手绘体素或修改器链改动后调用：丢弃缓存体积，下次取数重新求值。
##
## 【为什么由调用方显式调，而不是本类订阅 QVoxObject 的信号】手绘一笔就是一次体素写入，
## 若每次写入都自动作废，拖拽一笔（几十次写入）会连开几十次全量求值。粒度必须落在
## "一笔结束"上，而只有调用方知道一笔何时结束（QVoxelier 的画笔正是这么调的）。
## 求值精度仍由引擎的签名比对兜底：没真变的部分一次遍历都不做。
func invalidate() -> void:
	_invalidate()


## 上一次求值结果。只在 _build_mutex 内读写（_build_volume 由父类串行化），
## 故不需要额外加锁；主线程从不读它。
var _last: QVoxEvalResult = null


func _has_source() -> bool:
	return object != null


## 在 worker 线程内被调用（见父类 _build_volume 的并发契约）。
## 只读 object（不写、不锁），全部可观测状态都落在返回值里。
func _build_volume(grid_size: Vector3i) -> PackedInt32Array:
	var ctx := QVoxEvalContext.make(grid_size, eval_seed)
	var res := QVoxEvalEngine.evaluate(object, ctx, _last)
	_last = res
	return res.volume
