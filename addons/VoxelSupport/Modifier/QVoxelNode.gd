@tool
@abstract
class_name QVoxelNode
extends Resource
## 节点 —— 场景树上的一格（组或模型），树形层级结构的唯一元素类型。
## 【为什么是树，而不是"对象数组 + 扁平图层"】层与对象本是同一件事的两半 —— 层负责分组、
## 可见性、顺序，对象负责内容。拆成两张表，改一处就得同步另一处（"删层要把层内对象的 layer
## 一起撤销"就是这么来的）。合成一棵树后，"分组 / 可见 / 锁定 / 位置"都是节点属性
## —— **每样只有一处真值**，也不再需要"层"这个概念 —— **组就是层**。
## 【两个子类，一条分界】分界只有一条：**谁能持有手绘体素**。
##     QVoxelGroup  组 = 文件夹（容器，唯一可持有子节点）；内容是子树合并的结果，自己不存体素。
##     QVoxelModel  模型 = 图层（叶子，唯一持有手绘体素）。
## 于是"组"的内存成本为零（不存体素、也没有自己的画布尺寸，见 QVoxelEvalEngine 的紧致盒）。
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

## 可见性。**沿树继承**：父节点不可见 → 整棵子树不参与合成。
@export var visible := true

## 锁定。沿树继承：父节点锁定 → 整棵子树不可编辑（但仍照常求值，因为它可能是别的节点的输入）。
@export var locked := false

## 本节点在父画布里的位置（体素单位）。模型/组都可用：组偏移会带着整棵子树一起挪。
## 【为什么又回到"节点自带位置"】旧设计把摆放做成链上的一条平移修改器，代价是每个节点都背着
## 一条随时生效的求值链。体素建模要的是"把这块摆在哪儿"这一件事，故位置回到节点本身：
## 一处数据、一处编辑，不能再被旁通/重排/撤销链牵着走。
@export var offset := Vector3i.ZERO

## 树面板里的展开状态。**纯 UI 状态**：不入档、不参与 signature（它不是数据，
## 展开与否不改变任何求值结果）。放在这里而不是面板里，是因为面板每次重投影都重建行，
## 状态得有地方活着。
var expanded_in_tree := true

## 结构性改动（改名、可见性、位置、树形增删）。
## 【体素写入刻意不发这个信号】一笔画下来可能改几千格，逐格发信号会把 UI 拖死。手绘的刷新时机
## 由"手势封口"决定（见 QVoxelModel.base_revision 与 QVoxelEditCommand）。
signal content_changed


# 子类回答的问题

## 落盘判别键，取 KIND_GROUP / KIND_MODEL 之一。
@abstract
func kind() -> String


## 子节点（只有组非空）。返回**活引用**，改动一律走 QVoxelWorld 的树操作（保证撤销与标脏）。
func children() -> Array[QVoxelNode]:
	return []


# 共同行为

func is_group() -> bool:
	return kind() == KIND_GROUP


func is_model() -> bool:
	return kind() == KIND_MODEL


## UI 显示名：优先 node_name，其次带编号的默认名。
func display_name() -> String:
	if not node_name.is_empty():
		return node_name
	return "未命名组" if is_group() else "未命名模型"


## 本节点（含子树）在世界里的绝对偏移：逐层累加 offset。
## 渲染 / 求值据此把子树内容摆到父画布的对应位置。
func absolute_offset() -> Vector3i:
	return offset
