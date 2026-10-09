@tool
@abstract
class_name QVoxelNode
extends Resource
## 节点 —— 场景树上的一格（组或模型），树形层级结构的唯一元素类型。
##
## 【为什么是树，而不是"对象数组 + 扁平图层"】层与对象本是同一件事的两半 —— 层负责分组、
## 可见性、顺序，对象负责内容。拆成两张表，改一处就得同步另一处（"删层要把层内对象的 layer
## 一起撤销"就是这么来的）。合成一棵树后，"分组 / 可见 / 锁定"是节点属性，"挂滤镜 / 摆放"
## 是链上的条目 —— **每样只有一处真值**，也不再需要"层"这个概念 —— **组就是层**。
##
## 【两个子类，一条分界】分界只有一条：**谁能持有手绘体素**。
##     QVoxelGroup  组 = 文件夹（容器，唯一可持有子节点）；内容是子树合并的结果，自己不存体素。
##     QVoxelModel  模型 = 图层（叶子，唯一持有手绘体素）。
## 于是"组"的内存成本为零（不存体素、也没有自己的画布尺寸，见 QVoxelEvalEngine 的紧致盒）。
##
## 【为什么组也能挂修改器】这就是"在层级上挂滤镜"（PS 的组调整图层 / 组蒙版）。组的链作用于
## **子树合并结果**，于是"给整组岩石统一去色 / 侵蚀 / 镜像"是一件事，而不是逐个模型做十遍。
##
## 【为什么摆放也入链，而不是留在节点上】见 PcgTransform 类头：摆放（我在父画布里站哪儿）与
## "对内容做一次变换"要回答同一组问题 —— 谁先谁后、能否旁通、怎么撤销、怎么落盘。留在节点上
## 就等于给"变换"开第二个入口：链上的旋转 / 镜像得回答"我和节点摆放谁先谁后"，而"拖一下"也要
## 另写一套命令、另写一套存档。入链之后全项目只有一种画法（QVoxelTransformModifier）。
##
## 【为什么不存 parent 指针】父 → 子只朝一个方向（QVoxelGroup.child_nodes），于是引用图是 DAG、
## 没有环。Resource 是 RefCounted：存反向指针就造出环，环永远不会被释放（静默泄漏）。
## 需要"我在谁下面"时由 QVoxelWorld 从根往下找（find_parent / siblings_of），成本可忽略。

## 落盘判别键（NODE 的 nodes[] 里每项的 kind）。
const KIND_GROUP := "group"
const KIND_MODEL := "model"

## 全部 kind（读盘校验 / 报错文案用）。
const KINDS: PackedStringArray = [KIND_GROUP, KIND_MODEL]


## 显示名（写进 NODE 节点的 name 键）。留空则由子类给一个带编号的默认名。
@export var node_name := ""

## 可见性。**沿树继承**：父节点不可见 → 整棵子树不参与求值（见 QVoxelEvalEngine）。
@export var visible := true

## 锁定。沿树继承：父节点锁定 → 整棵子树不可编辑（但仍照常求值，因为它可能是别的节点的输入）。
@export var locked := false

## 本节点自己的滤镜链。顺序即语义（与 Blender 的修改器栈同理：换位置就是换语义）。
## 模型的链作用于"自己的手绘体素"；组的链作用于"已经摆好的子树合成结果"。
##
## **摆放也在其中**：链上一条平移条目（QVoxelTransformModifier + PcgTransform 的 TRANSLATE）把
## 整块结果挪到别处，引擎据此填 result.origin。故节点上既没有位置、也没有"与父画布合成方式"。
@export var modifiers: Array[QVoxelModifier] = []

## 树面板里的展开状态。**纯 UI 状态**：不入档、不参与 signature（它不是数据，
## 展开与否不改变任何求值结果）。放在这里而不是面板里，是因为面板每次重投影都重建行，
## 状态得有地方活着。
var expanded_in_tree := true

## 结构性改动（链增删/重排、修改器参数变化、改名、可见性、树形增删）。
##
## 【体素写入刻意不发这个信号】一笔画下来可能改几千格，逐格发信号会把 UI 拖死。手绘的刷新时机
## 由"手势封口"决定（见 QVoxelModel.base_revision 与 QVoxelEditCommand）。
##
## 【修改器参数变化为什么不在这里自动监听】QVoxelModifier 是 Resource，Godot 不会替我们监听它的
## @export 改动，所以"改参数要标脏"由改参数的那条命令负责（QVoxelPropertyCommand 在 redo/undo
## 之后 emit 本信号），本类只管自己结构变化时发出。
signal content_changed


# ----------------------------------------------------------------------------
# 子类回答的问题
# ----------------------------------------------------------------------------

## 落盘判别键，取 KIND_GROUP / KIND_MODEL 之一。
@abstract
func kind() -> String


## 子节点（只有组非空）。返回**活引用**，改动一律走 QVoxelWorld 的树操作（保证撤销与标脏）。
func children() -> Array[QVoxelNode]:
	return []


# ----------------------------------------------------------------------------
# 共同行为
# ----------------------------------------------------------------------------

func is_group() -> bool:
	return kind() == KIND_GROUP


func is_model() -> bool:
	return kind() == KIND_MODEL


## UI 显示名：优先 node_name，其次带编号的默认名。
func display_name() -> String:
	if not node_name.is_empty():
		return node_name
	return "未命名组" if is_group() else "未命名模型"


## 参与判脏的签名 —— 供求值引擎判断"这个节点（含其链）变了没有"。
##
## 【可见性为什么在签名里】它改变的是"本节点相对父画布的输出"（不可见 → 整棵子树不参与合成），
## 组求值时必须反映出来。名字 / 锁定不影响输出，故不在签名里。
##
## 【摆放为什么不必在这里】它已经是链上的一条 —— 挪一下就是改那条的参数，会随
## active_modifiers() 的 signature 一起变，多存一份反而要回答"两处不一致时听谁的"。
func signature() -> String:
	var parts := PackedStringArray()
	parts.append("%s|%d|%s" % [kind(), int(visible), node_name])
	for m in active_modifiers():
		parts.append(m.signature())
	return "|".join(parts)


# ----------------------------------------------------------------------------
# 链的编辑入口（UI 把这些包进 QVoxelPropertyCommand 后再调用，以保证撤销正确）
# ----------------------------------------------------------------------------

## 追加一条修改器。
##
## 【为什么不接受"算子 + 合成方式"两个裸参数】条目必须自带开关与合成方式，而这些属于修改器
## 而不属于算子（同一棵 Sdf 树既能被并进去，也能被减掉）。所以由调用方先
## `QVoxelModifierSerializer.new_modifier(kind)` 造一个空条目、填好核再追加，而不是在这里替它猜默认值。
func add_modifier(modifier: QVoxelModifier) -> QVoxelModifier:
	if modifier == null:
		return null
	modifiers.append(modifier)
	content_changed.emit()
	return modifier


func remove_modifier(index: int) -> void:
	if index < 0 or index >= modifiers.size():
		return
	modifiers.remove_at(index)
	content_changed.emit()


## 重排（纯数据操作，不依赖任何 context —— 与 Blender 的 modifiers.move 同理）。
func move_modifier(from: int, to: int) -> void:
	var n := modifiers.size()
	if from < 0 or from >= n or to < 0 or to >= n or from == to:
		return
	var m := modifiers[from]
	modifiers.remove_at(from)
	modifiers.insert(to, m)
	content_changed.emit()


## 参与求值的修改器（保持原顺序）。
func active_modifiers() -> Array[QVoxelModifier]:
	var out: Array[QVoxelModifier] = []
	for m in modifiers:
		if m != null and m.is_active():
			out.append(m)
	return out
