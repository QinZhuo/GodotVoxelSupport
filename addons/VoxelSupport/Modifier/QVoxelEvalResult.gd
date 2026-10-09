class_name QVoxelEvalResult
extends RefCounted

## 求值结果 —— 一条链跑完之后的数据形态，外加"它是怎么来的"。
##
## 【为什么把结果单独成一个对象，而不是让引擎返回一堆值】求值引擎是纯函数、无状态（见
## QVoxelEvalEngine），但调用方需要同时拿到好几样东西：链停在哪个域、折叠好的 Sdf 树、
## 降级后的体积、以及"这次结果的输入签名"。返回一个对象让这些字段各自有名字，
## 比返回一个 5 元组更容易读懂，也让"增量复用"（把上一次结果原样传回来）成为一行判断。
##
## 【为什么不缓存到引擎里】引擎若持有上一次结果，就必须持有对象引用与订阅信号才能知道自己脏了 ——
## 那它就从一个纯函数变成一个带状态的单例，而"谁在什么线程上求值"会立刻变成并发问题。
## 结果由调用方保管、求值时作为入参传回，引擎保持无状态。

## 链最终停在的域（QVoxelDomain.Kind）。空链 = VOXEL（只有手绘基础体素）。
##
## 【它是"链的终点"，不是"产出数据的形态"】引擎总是把结果物化成一块体积（本项目的消费者
## 都在体素侧），故这里报 FIELD 时 volume 同样有值 —— 报 FIELD 的含义是
## "这条链还能继续追加场域算子"。编辑器据此决定菜单里哪些算子可加、哪些要灰掉；
## "我拿到的到底是什么"由 `field` / `volume` 哪个非空直接回答。
## 需要"链停在哪"而不想求值一遍时，用 QVoxelDomain.final_domain(obj.modifiers)。
var domain: QVoxelDomain.Kind = QVoxelDomain.Kind.VOXEL

## 本次求值的体积尺寸（体素）。
##
## 【它是**产出**的尺寸，不一定是输入的尺寸】重排型修改器（QVoxelTransformModifier）会改盒尺寸，
## 故本字段是"链跑完之后有多大"。调用方（生成器 / UI）据此设置 QVoxelSource.grid_size 与显示读数；
## 而链的**输入**盒尺寸是 QVoxelModel.grid_size（见 QVoxelEvalEngine 的输入键）。
var grid_size := Vector3i.ZERO

## 本体积的 (0,0,0) 在**父画布**里的整数偏移 —— 树形求值的"摆放"结果。
##
## 【为什么体积不能总是"按父画布尺寸的整张"】组的内容按"子树并集包围盒"（紧致盒）给，
## 于是每个结果都自带"我这个盒的左下角在父画布里是哪儿"，合成由调用方按本字段对齐。
## 组因此不必按世界画布分配（512³ 一次分配就是 537 MB，见 DESIGN §2.3）。
##
## 【它是链的产出，不是节点字段】链上的平移条目（PcgTransform 的 TRANSLATE）把整块结果挪到
## 别处，累加结果就写在这里（见 QVoxelEvalEngine._run_chain）。于是"摆放"与镜像 / 旋转一样
## 只是一条链条目 —— 节点上没有第二份摆放，也没有第二套"谁先谁后"的答案。
var origin := Vector3i.ZERO

## FIELD 段折叠出的 Sdf 树（没有 FIELD 修改器时为 null）。降级后仍保留，供上层复用/调试。
var field: Sdf = null

## 产出体积（布局 = PcgModel.index_of）。手绘体素为空、链也没产出时才为空数组。
## 只要链里有 FIELD 或 VOXEL 算子就会有值（降级点由引擎自动插入，见 QVoxelEvalEngine）。
var volume := PackedInt32Array()

## 输入签名（见 QVoxelEvalEngine.input_signature）。同签名 + 同 epoch = 结果可复用。
var input_signature := ""

## 本次求值的序号（QVoxelEvalContext.epoch）。用于丢弃过期结果。
var epoch := 0

## 逐步骤检查点（见 QVoxelEvalEngine 的「逐步骤判脏」）。
##
## 【下标含义】states[i] = 跑完前 i 条**参与求值**的修改器之后的累积状态，故
## states.size() == active_modifiers().size() + 1：
##   states[0]  = 链的输入（手绘体素 + 空场），即 §5.2 里的 `base`
##   states[n]  = 最终产出（与 volume 同值）
## 求值被取消时本数组连同 step_signatures 一起清空 —— 截断的轨迹不能当复用起点。
##
## 【为什么必须逐步存，而不是只存"上一次的结果"】只存最终体积时，复用只发生在"整链一字未改"
## 的场合；改链尾一条参数仍要从前到后重跑整条链（含昂贵的程序化生成 / 场光栅化）。逐步检查点
## 让"改第 k 条"的代价只与第 k 条之后有多长成正比 —— 这正是 §5.2 的逐步骤判脏。
##
## 【内存账】FIELD 段的检查点只有一棵 Sdf 树（零体积开销）；VOXEL 段每一步各持一份体积副本
## （32³ = 128 KB，256³ = 67 MB）。项目默认 32³、链长个位数，故常驻可接受；若将来要支持
## 512³ 上的长链，这里就是第一个需要做上限/落盘的地方。
##
## 【为什么是副本而不是引用】PackedInt32Array 赋值是**共享缓冲**（写一处即改全部），而
## PcgDetail.apply 是就地改写型算子：不复制就会顺手把上一步的检查点改掉。
var states: Array = []

## 链的**输入**键（不含逐步骤签名）：对象身份 + 网格 + 种子 + 块大小 + 手绘版本号。
## 它一变，所有检查点全部作废 —— 那意味着"链之前"的输入换了，连 states[0] 都不再成立。
var inputs_key := ""

## 本次求值时各参与条目的 signature()（与 active_modifiers() 一一对应）。与上一次结果逐条
## 比对即可定位"第一条变了的条目" = 可复用的最长前缀长度（见 QVoxelEvalEngine._resume_index）。
var step_signatures := PackedStringArray()


## 一步的累积状态。FIELD 段里场树有值、体积为空（还没降级）；降级之后反过来。
##
## 【为什么 field 与 volume 都要存】FIELD 段折叠的是 Sdf 树而不是体积，检查点落在场里时
## "累积结果"就是那棵树；落在体素段时才是体积。存了树，复用路径上 res.field 才照样有值
## （"场域结果要留在结果里，便于换分辨率重光栅化"）。
class StepState:
	extends RefCounted

	## 累积出的 Sdf 树（体素段里保持"降级那一刻"的树，供上层复用/调试）。
	var field: Sdf = null

	## 累积出的体积。**空数组 = 还没物化成体积**（仍在 FIELD 段内，或降级时场为空）。
	var volume := PackedInt32Array()

	## 降级点是否已越过。不能只看 volume 空不空：光栅化出全零是合法的"降级完了但结果为空"。
	var degraded := false

	## 这一步之后**当前盒的尺寸**。重排型修改器会改它，而后续的就地改写型算子必须拿到正确的
	## 尺寸（`PcgDetail.apply(volume, grid_size, seed)` 会按下标遍历整块），故它属于累积状态本身，
	## 而不是"链的输入尺寸"。
	var box := Vector3i.ZERO

	## 这一步之后**整块结果被挪到哪儿**（链上平移条目累积，见 PcgTransform.origin_delta）。
	##
	## 【为什么它也必须进检查点】与 box 同理：它是累积状态，不是链的输入。漏了它，"从中间接着跑"
	## 就会把前面平移过的位移丢掉 —— 表现为"改链尾一条参数，模型突然跳回原点"。
	var shift := Vector3i.ZERO

	## 复制一份。复用检查点时必须走这里：PcgDetail 就地改写会顺着共享缓冲改到原检查点。
	func duplicate_state() -> StepState:
		var s := StepState.new()
		s.field = field
		s.volume = volume.duplicate()
		s.degraded = degraded
		s.box = box
		s.shift = shift
		return s


## 是否有可用体积（域停在 VOXEL 且产出非空）。
func has_volume() -> bool:
	return not volume.is_empty()


## 实心体素数量（UI 状态栏用）。
func solid_count() -> int:
	var n := 0
	for m in volume:
		if m > 0:
			n += 1
	return n
