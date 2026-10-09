@tool
class_name QVoxelModelGenerator
extends PcgModelGenerator

## 适配器：把 QVoxelModel（手绘体素 + 修改器链）接到 VoxelGenerator（逐 chunk 供数）上。
##
## 【与父类的关系】"整块体积 → 逐 chunk"的缓存、切片、LOD 采样全部继承自 PcgModelGenerator，
## 本类只换掉"体积从哪来"这一件事（覆写 _has_source / _build_volume）。于是这条路径
## 全项目只有一份实现：不管体积出自 L-系统、元胞自动机、WFC 还是修改器链，
## 切片侧看到的都是同一个 VoxelGenerator 契约。
##
## 【为什么链不走"边切片边采样"】SDF 逐点采样天生适合按 chunk 懒算，但**细节层需要完整邻域**：
## 风化判定暴露面、染色挑色阶都要看邻居，按 chunk 各算各的会在 chunk 边界留下接缝。
## 故链一律"先生成完整体积，再进链"——代价是有界模型要常驻一份体积。
##
## 【用法】
##   var gen := QVoxelModelGenerator.new()
##   gen.object = my_qvx_model       # 手绘体素 + 修改器链（SDF 生产 → 风化 → 染色 → 镜像）
##   gen.eval_seed = 20261007
##   var data := VoxelData.new(); data.generator = gen
##   data.grid_size = gen.output_grid_size()   # ← 注意：不是 object.grid_size（见下）
##
## 【为什么 grid_size 要问 output_grid_size()，而不是照抄 object.grid_size】链里可能有**重排型**
## 修改器（QVoxelTransformModifier：镜像 / 旋转 90° / 平铺），它们会改盒尺寸。`VoxelData.grid_size`
## 描述的是"渲染出来多大"，故它必须取**求值后**的尺寸；而链的**输入**尺寸恒为 object.grid_size。
## 两者不一致时以 output_grid_size() 为准，_build_volume 会核对（对不上就说明调用方漏同步了）。
##
## 【增量复用】上一次的求值结果留在 _last 里：主线程只调了一次参数、什么都没变时，
## 下一次求值（例如改一条修改器后按 chunk 重建）由引擎的签名比对直接返回旧结果，
## 一次遍历都不做。改动链之后调用 invalidate() 即可，签名比对负责判断是否真的要重算。

## 要渲染的对象（手绘体素 + 修改器链）。
@export var object: QVoxelModel:
	set(value):
		if object == value:
			return
		object = value
		_invalidate()


## 求值种子（透传给 QVoxelEvalContext.seed，是全链共用的主种子）。
@export var eval_seed: int = 0:
	set(value):
		if eval_seed == value:
			return
		eval_seed = value
		_invalidate()


## 对象的手绘体素或修改器链改动后调用：丢弃缓存体积，下次取数重新求值。
##
## 【为什么由调用方显式调，而不是本类订阅 QVoxelModel 的信号】手绘一笔就是一次体素写入，
## 若每次写入都自动作废，拖拽一笔（几十次写入）会连开几十次全量求值。粒度必须落在
## "一笔结束"上，而只有调用方知道一笔何时结束（QVoxelier 的画笔正是这么调的）。
## 求值精度仍由引擎的签名比对兜底：没真变的部分一次遍历都不做。
func invalidate() -> void:
	_invalidate()


## 上一次求值结果。只在 _build_mutex 内读写（_build_volume 由父类串行化），
## 故不需要额外加锁；主线程从不读它。
var _last: QVoxelEvalResult = null


## 本对象的**求值输出**盒尺寸 —— 调用方据此设置 VoxelData.grid_size（先算尺寸、再要体积）。
##
## 【为什么它是纯函数、不必求值】只有重排型条目会改盒尺寸，故沿链把 reshape 的尺寸映射叠起来即可
## （见 QVoxelEvalEngine.output_grid_size）。于是 UI 能在改完变换参数的那一帧就把 grid_size 同步好，
## 不必等 worker 线程跑完一次全量求值。
func output_grid_size() -> Vector3i:
	if object == null:
		return Vector3i.ZERO
	return QVoxelEvalEngine.output_grid_size(object.modifiers, object.grid_size)


## 有产出源吗？与父类不同，"源"是手绘体素 + 修改器链，而不是 model 字段。
##
## 【为什么不能沿用父类判断】父类问的是 `model != null`（PcgModel 那一路的源），
## 本类的 object 才是源；不覆写则 _ensure_volume 永远认为"无源"，整块体积恒为空。
## 手绘体素也算源——即使链为空，object.grid_size 内可能已有手绘体素。
func _has_source() -> bool:
	return object != null


## 在 worker 线程内被调用（见父类 _build_volume 的并发契约）。
## 只读 object（不写、不锁），全部可观测状态都落在返回值里。
##
## 【传入的 grid_size 是"输出盒"，链的输入盒另有其源】见类头。故这里刻意**不用**形参当输入尺寸，
## 只用它做一次一致性核对 —— 对不上就说明调用方没把 data.grid_size 同步成 output_grid_size()，
## 此时渲染侧会按错误的 AABB 切片（画面缺角而不是报错），必须显式喊出来。
func _build_volume(grid_size: Vector3i) -> PackedInt32Array:
	if object == null:
		return PackedInt32Array()
	var ctx := QVoxelEvalContext.make(object.grid_size, eval_seed)
	var res := QVoxelEvalEngine.evaluate(object, ctx, _last)
	_last = res
	if res.grid_size != grid_size:
		push_warning("[QVX] data.grid_size（%s）与求值输出盒（%s）不一致：调用方应改用 generator.output_grid_size()"
				% [grid_size, res.grid_size])
	return res.volume
