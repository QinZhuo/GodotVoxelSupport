@tool
class_name PcgTransform
extends Resource

## 体素变换算子 —— 镜像 / 旋转 90° / 平铺 / **平移**，即"**在链上改整块结果形态**"的第二类能力。
##
## 【为什么不能塞进 PcgDetail】PcgDetail 的契约明写"不得改变 grid_size"（就地改写）；而重排
## 天生要改盒尺寸（旋转互换两轴、平铺成倍放大）。硬塞进去会让那份契约长出一个例外，
## 而例外的数量正是"引擎自动插入降级点"这类能力失效的起点。于是体素域有**两类**能力，
## 判据仍是方法存在性（不给算子加基类，见 QVoxelDomain 的能力签名表）：
##     apply(volume, grid_size, seed)              —— 就地改写（PcgDetail）
##     reshape(volume, grid_size) -> [体积, 尺寸]   —— 重排 / 摆放（本类）
##
## 【为什么"平移"和旋转缩放同住本类，而不是回到节点字段】摆放（我在父画布里站哪儿）与
## "对内容做一次变换"本是同一件事的两半：都要求"整块结果 + 一个几何变换"，都被链的顺序与
## 旁通左右，也都要进同一份落盘 / 撤销 / 校验。做成节点字段就等于给"变换"开第二个入口 ——
## 于是"拖一下"要另写一套命令、另写一套存档、另写一套重排规则，而链上的那条（旋转 / 镜像）
## 又得回答"我和节点摆放谁先谁后"。入链之后它自动获得链上的一切待遇，且全项目只有一种画法。
##
## 【平移为什么不改盒尺寸，也不改体积】镜像 / 旋转 / 平铺改的是"内容在盒里怎么排"；平移改的
## 是"这个盒在父画布里站哪儿"（QVoxelEvalResult.origin）。硬按"往盒里补零把内容推到偏移处"来做，
## 负偏移就无从表达（盒的左下角恒在 0），远处的一个模型也会撑出一只巨盒。故 reshape() 对平移
## 原样交还体积与尺寸，位移由 origin_delta() 单独回答 —— 两个问题各有各的出口，互不冒充。
##
## 【本类不做数学】整数格语义完全复用 QVoxelTransform（置换 + 符号的 48 种双射 + 平铺复制族），
## 本类只把"用户选的那一种变换"翻译成它的一次调用 —— 于是"哪些变换是合法的"这件事
## 全项目只有一份实现，不会出现第二处手写的轴字母表。
##
## 【为什么核是 Resource 而 QVoxelTransform 不是】核要能被多个修改器共享、要能落盘、
## 要进签名比对 —— 那三件事都要求它是 Resource；QVoxelTransform 是纯函数工具，不是资源。

## 变换种类。
enum Mode {
	MIRROR, ## 沿某轴镜像（网格尺寸不变）
	ROTATE, ## 绕某轴转 90°（另两轴尺寸互换）
	REPEAT, ## 沿某轴平铺 times 份（该轴尺寸变 times 倍）
	TRANSLATE, ## 平移 offset（体积与盒尺寸都不变，只改摆放）
}

## 种类名（UI 下拉框用）。**只增不改序**：落盘存的是枚举值，插在中间会让旧文件换义。
const MODE_NAMES: PackedStringArray = ["镜像", "旋转 90°", "平铺", "平移"]

## 轴名（UI 下拉框用）。
const AXIS_NAMES: PackedStringArray = ["X", "Y", "Z"]

## 一次重排后的**格数上限**。与 MagicaVoxel 的 256³ 同阶：256³ ≈ 1677 万格 ≈ 64 MB 体积，
## 再加上逐步骤检查点与撤销快照，量级已不小；而平铺很容易顶到它（256³ ×2 = 1.3 亿格）。
##
## 【为什么上限在核里，而不在"加修改器"那个按钮上】重排条目是链上的**持久**记录：
## 加修改器 / 改参数 / 撤销重做 / 读盘四条路径都会让它生效。上限只写在 UI 入口那一处，
## 另外三条照样能把网格撑到 1.3 亿格 —— 而那种卡死没有提示，用户只会以为程序崩了。
## 放在核里，四条路径自动一致。
const MAX_OUTPUT_VOXELS := 256 * 256 * 256


## 变换种类。
@export var mode: Mode = Mode.MIRROR

## 作用轴（0 = X，1 = Y，2 = Z）。
@export_range(0, 2) var axis := 0

## 旋转方向：+1 / -1。其余种类忽略本字段。
@export_range(-1, 1) var direction := 1

## 平铺份数。其余种类忽略本字段。
@export_range(1, 16) var times := 2

## 平移量（体素）。其余种类忽略本字段。**可为负** —— 负偏移正是"盒内补零"方案表达不了的半边。
@export var offset := Vector3i.ZERO


## 便捷构造：镜像 axis 轴。
static func mirror(axis_: int) -> PcgTransform:
	var t := PcgTransform.new()
	t.mode = Mode.MIRROR
	t.axis = clampi(axis_, 0, 2)
	return t


## 便捷构造：绕 axis 轴转 90°。
static func rotate(axis_: int, dir: int = 1) -> PcgTransform:
	var t := PcgTransform.new()
	t.mode = Mode.ROTATE
	t.axis = clampi(axis_, 0, 2)
	t.direction = 1 if dir >= 0 else -1
	return t


## 便捷构造：沿 axis 轴平铺 times 份。
static func repeat(axis_: int, times_: int = 2) -> PcgTransform:
	var t := PcgTransform.new()
	t.mode = Mode.REPEAT
	t.axis = clampi(axis_, 0, 2)
	t.times = maxi(1, times_)
	return t


## 便捷构造：平移 offset 个体素（摆放）。
static func translate(offset_: Vector3i) -> PcgTransform:
	var t := PcgTransform.new()
	t.mode = Mode.TRANSLATE
	t.offset = offset_
	return t


## 本条目把整块结果**平移**多少（体素）。只有平移会挪，其余种类恒为零。
##
## 【为什么它不在 reshape 的返回值里】见类头：平移改的是"盒站哪儿"而不是"盒里怎么排"。
## 引擎把本值累加进 QVoxelEvalResult.origin，于是负偏移、远处的模型都不必付"撑大盒"的代价。
func origin_delta() -> Vector3i:
	return offset if mode == Mode.TRANSLATE else Vector3i.ZERO


## 重排整块体积。返回 `[体积, 尺寸]`（尺寸即新的盒尺寸）。
##
## 【为什么连尺寸一起返回，而不是让调用方自己算】"新尺寸"与"新体积"必须一致 ——
## 分成两个入口时，调用方漏调一个就会得到"数组长度与盒尺寸对不上"的静默错位
## （正是最坏的一类 bug：不报错、只是画面错）。一次返回两件，错位在类型上就不可能发生。
func reshape(volume: PackedInt32Array, grid_size: Vector3i) -> Array:
	# 平移不改体积、也不改盒尺寸（位移由 origin_delta 单独回答，见类头）。放在上限判定之前：
	# 它的产出尺寸恒等于输入，不存在"超限"这回事，多走一次判定只会让两条路径的答案需要对齐。
	if mode == Mode.TRANSLATE:
		return [volume, grid_size]
	var raw := raw_output_size(grid_size)
	if not within_budget(raw):
		# 超限 / 尺寸非法：**原样返回**。与 output_size() 给出同一个答案 ——
		# 若这里返回新尺寸而那边返回旧尺寸，data.grid_size 就会与实际体积长度不符。
		return [volume, grid_size]
	if mode == Mode.REPEAT:
		return [QVoxelTransform.repeat_volume(volume, grid_size, axis, times), raw]
	return [transform_of().remap(volume, grid_size), raw]


## 变换后的盒尺寸（纯函数：不碰体积，故 UI 能在求值之前先把 data.grid_size 算出来）。
##
## 超限时**原样返回 grid_size** —— 与 reshape() 拒绝执行是同一个答案（见 within_budget）。
func output_size(grid_size: Vector3i) -> Vector3i:
	var raw := raw_output_size(grid_size)
	return raw if within_budget(raw) else grid_size


## 重排后的盒尺寸，**不含上限判定**。
##
## 【为什么要暴露"未判定的尺寸"】上限生效时 output_size() 只会静静地原地不动，而 UI 恰恰需要
## 看见那个超限的尺寸才能告诉用户"会撑到多大、为什么没执行"。判据仍是同一个 within_budget，
## 故"提示"与"实际生效"永远不会说两套话。
func raw_output_size(grid_size: Vector3i) -> Vector3i:
	match mode:
		Mode.REPEAT:
			return QVoxelTransform.repeat_size(grid_size, axis, times)
		Mode.ROTATE:
			return transform_of().new_size(grid_size)
	return grid_size


## 盒尺寸是否在可承受范围内（见 MAX_OUTPUT_VOXELS）。
##
## 【为什么做成静态纯函数】output_size()、reshape() 与 UI 的预检要给出**同一个**答案，
## 而"上限是多少"这件事只应有一处。三处各写一遍迟早会判得不一样。
static func within_budget(size: Vector3i) -> bool:
	return size.x > 0 and size.y > 0 and size.z > 0 \
			and size.x * size.y * size.z <= MAX_OUTPUT_VOXELS


## 本变换对应的双射（只有 MIRROR / ROTATE 用；REPEAT 是复制族、TRANSLATE 只挪摆放，
## 两者都不是"格到格的双射"，见 QVoxelTransform）。
func transform_of() -> QVoxelTransform:
	if mode == Mode.ROTATE:
		return QVoxelTransform.rotate90(axis, direction)
	return QVoxelTransform.mirror(axis)


## UI 显示名（"镜像 X" / "旋转 90° Z" / "平铺 X ×2" / "平移 (2, 0, -4)"）。
func display_name() -> String:
	if mode == Mode.TRANSLATE:
		return "平移 (%d, %d, %d)" % [offset.x, offset.y, offset.z]
	var a: String = AXIS_NAMES[clampi(axis, 0, 2)]
	match mode:
		Mode.ROTATE:
			return "旋转 90° %s%s" % [a, "" if direction >= 0 else "（反向）"]
		Mode.REPEAT:
			return "平铺 %s ×%d" % [a, maxi(1, times)]
	return "镜像 %s" % a
