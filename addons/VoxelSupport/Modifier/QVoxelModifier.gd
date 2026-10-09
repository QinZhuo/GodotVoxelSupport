@tool
@abstract
class_name QVoxModifier
extends Resource

## 修改器 —— 非破坏链上的**唯一**条目类型。
##
## 【链条目只有一种东西】一条链完全由修改器组成，包括并 / 差 / 交：布尔不是"另一种条目"，
## 而是修改器的 combine（见 QVoxDomain.Combine）。于是"挂一个修改器"就是引擎认识的全部操作，
## 用户也只需要理解这一件事。
##
## 【共同基类】本类管一条修改器**怎么用**（开关 / 合成方式 / 平滑量 / 种子 / 显示名 / 落盘）；
## 子类只回答**算法核是谁**，并把核的类型收紧到自己的域：
##     QVoxSdfModifier       核 = Sdf 子树      域 = 连续（FIELD）     引擎调 op.sample(p)
##     QVoxModelModifier     核 = PcgModel      域 = 体素（VOXEL）源   引擎调 op.build(grid)
##     QVoxVolumeModifier    核 = PcgDetail     域 = 体素（VOXEL）改写  引擎调 op.apply(...)
##     QVoxTransformModifier 核 = PcgTransform  域 = 体素（VOXEL）变换  引擎调 op.reshape(...)
## 域因此是**类型**而不是探测结果：不可能构造出"自称连续域、核却只会 apply"的状态；
## 引擎也不必再问"你有没有 sample 方法"——子类本身就是那份契约。
##
## 【算法核为什么仍是独立资源】算子是可复用的纯逻辑，参数化后能被多个修改器共享
## （一个 SdfBox 挂到十个对象上，改一次全体同步）；"这一次怎么用"才是逐条目的。
## 这与 Houdini 的「节点实例 + 共享资产」同构。Blender 选择「每条目自带一份参数实例」，
## 换来更少的概念，代价是修改器不能被共享。
##
## 【可重排 / 可旁通】顺序即语义，与 Blender 的修改器栈同理：move_modifier() 换位置，
## enabled = false 旁通而不移除。


## 落盘判别键 —— 决定读盘时造哪个子类。取值见 KINDS。
const KIND_SDF := "sdf"
const KIND_MODEL := "model"
const KIND_VOLUME := "volume"
const KIND_TRANSFORM := "transform"

const KINDS: PackedStringArray = [KIND_SDF, KIND_MODEL, KIND_VOLUME, KIND_TRANSFORM]

## 判别键的中文名（UI 下拉框用）。
const KIND_NAMES: PackedStringArray = ["SDF 场", "体素生成", "体素处理", "体素变换"]


## 旁通开关（Houdini 的 bypass）。false 时不参与求值，但不从链上移除。
@export var enabled := true

## 自定义显示名。留空则用算子类名。
@export var label := ""

## 合成方式。连续域：决定它怎么并进已累积的场；体素域：只有"自足产出"的核才允许使用
## 「替换」之外的合成方式（就地改写型核拿不到输入，无法做布尔）。
@export var combine: QVoxDomain.Combine = QVoxDomain.Combine.UNION

## SMOOTH_UNION 的过渡宽度（体素单位）。建议与体素尺度同量级，过大将吞掉细节。
@export_range(0.0, 64.0, 0.1) var blend := 2.0

## 该条目的确定性骰子。逐条目独立而非全链共用：调换顺序时各自的随机不会跟着洗牌，
## 便于"只换位置、看画面差异"这种对比。
@export var seed := 0


# ----------------------------------------------------------------------------
# 子类回答的问题
# ----------------------------------------------------------------------------

## 落盘判别键，取 KIND_SDF / KIND_MODEL / KIND_VOLUME 之一。
@abstract
func kind() -> String


## 算法核（Sdf 子树 / PcgModel / PcgDetail）。null = 空条目，不参与求值。
@abstract
func op() -> Resource


## 替换算法核（读盘路径）。类型不符时返回 false（调用方据此丢弃这一条，而不是静默留空）。
## 传入 null 是合法的"空条目"，返回 true。
@abstract
func set_op(value: Resource) -> bool


# ----------------------------------------------------------------------------
# 共同行为
# ----------------------------------------------------------------------------

## 该条目所属的求值域。由 kind 唯一决定 —— kind 比域更细：体素域分"自足产出"与"就地改写"。
func domain() -> QVoxDomain.Kind:
	match kind():
		KIND_SDF:
			return QVoxDomain.Kind.FIELD
		KIND_MODEL, KIND_VOLUME, KIND_TRANSFORM:
			return QVoxDomain.Kind.VOXEL
	return QVoxDomain.Kind.MESH


## 是否为"自足产出"（源）。就地改写 / 重排型不是源：核被调用时已拿到输入，引擎无法在
## 事后替它做布尔，所以它的合成方式只能是「替换」（见 QVoxDomain.validate_chain）。
## 白名单而非"非 volume 即源"：将来加网格算子时不会意外把它算成源。
func is_source() -> bool:
	return kind() == KIND_SDF or kind() == KIND_MODEL


## 是否为"变换"型（镜像 / 旋转 90° / 平铺 / 平移）—— 整块结果的形态与摆放由核自己决定。
##
## 【为什么单独给一个判据】它是体素域里唯一会改盒尺寸 / 摆放的能力（就地改写型不得改尺寸，
## 见 PcgDetail 契约），引擎与 UI 都要据此分道走：求值要跟着更新当前盒尺寸与摆放偏移，
## 生成器要据此把 data.grid_size 同步成"求值后的尺寸"。
##
## 【平移也归这里，尽管它不改盒尺寸】判据回答的是"核自己说了算吗"，而不是"尺寸会不会变"——
## 平移与镜像走同一条 reshape 通道、同一条合成方式规则（只能是「替换」），拆成两个判据只会
## 让每处调用点都要多问一次，而答案永远一样。
func is_reshape() -> bool:
	return kind() == KIND_TRANSFORM


## 是否参与求值。
func is_active() -> bool:
	return enabled and op() != null


## UI 显示名：优先自定义 label，其次算子类名。
func display_name() -> String:
	if not label.is_empty():
		return label
	var o := op()
	return "（空修改器）" if o == null else QVoxModifierSerializer.op_type_name(o)


## 参与判脏的签名 —— 供求值引擎判断"哪些条目变了、能否复用上一步结果"。
##
## 【必须含 enabled】旁通开关翻转会改变链的输出，若签名只反映算子与参数，引擎会误判
## "没变"而复用旁通前的结果。凡影响输出的字段都在签名里（label 不影响输出，故不在）。
##
## 【为什么含实例 id】参数只改一个数字时，改动点**之前**的条目实例与参数都不变，前缀签名
## 自然相同。若只用类型+参数做签名，两棵参数相同的不同算子树会被误判为"没变"。
func signature() -> String:
	return "%d|%s|%d|%.4f|%d" % [int(enabled), QVoxModifierSerializer.op_signature(op()),
			combine, blend, seed]


# ----------------------------------------------------------------------------
# 落盘（NODE 的 steps 里的一项）
# ----------------------------------------------------------------------------

## 条目 → JSON 可表达的一项。**算子摊平到本层**（type / params），而不是嵌一个 "op" 子对象：
## 工程文件里一条修改器应该长得像一条可读的流水线指令，而不是层层套娃。
func to_dict() -> Dictionary:
	var d := {
		"kind": kind(),
		"enabled": enabled,
		"combine": int(combine),
		"blend": blend,
		"seed": seed,
	}
	if not label.is_empty():
		d["label"] = label
	var o := op()
	if o != null:
		var od := QVoxModifierSerializer.op_to_dict(o)
		d["type"] = od.get("type", "")
		d["params"] = od.get("params", {})
	return d
