@tool
@abstract
class_name QVoxelNode
extends Resource
## 节点 —— 场景树上的一格（组或模型），树形层级结构的唯一元素类型。
## 【为什么是树，而不是"对象数组 + 平行的分组表"】分组与对象本是同一件事的两半 —— 分组负责
## 归属与顺序，对象负责内容。拆成两张表，改一处就得同步另一处（"删分组要把组内对象的归属一起
## 改"就是这么来的）。合成一棵树后，"归属 / 可见 / 锁定 / 位置"都是节点属性
## —— **每样只有一处真值**，也没有"这个对象属于哪个分组"这种需要跨表校验的字段。
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

## 本节点在父画布里的**摆放**（位置 + 旋转）。模型/组都可用：组的变换会带着整棵子树一起走。
## 【唯一真值】整份工程里"节点在哪、朝向如何"只有这一份数据 —— 读盘、求值、导入、导出全走它。
## 旋转与 .vox 的 nTRN 同构（轴对齐 90° 倍数），故体素坐标取整后仍是整数，盒不被破坏。
## 缺省恒等（P2：不存可由缺省推出的值）。
@export var local_transform: Transform3D = Transform3D.IDENTITY

## 位置视图：`local_transform.origin` 的整数形态。**编辑与既有代码只用它**，
## 旋转则直接读 `local_transform.basis`。两处不是两份真值 —— offset 只是 origin 的一个视图。
var offset: Vector3i:
	get:
		return Vector3i(
				roundi(local_transform.origin.x),
				roundi(local_transform.origin.y),
				roundi(local_transform.origin.z))
	set(value):
		local_transform.origin = Vector3(value)

## 组的运行时编号（模型不用它，走落盘的 `model_id`）。**不落盘**：
## 只服务"脚本/树面板按标量定位一个组"这件事，重新读档后按遍历顺序重发。
## 与 `model_id` 共用一套 id 空间，靠符号区分（见 QVoxelWorld.node_id）。
var node_uid := 0

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

