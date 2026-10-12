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

## 逐帧摆放轨道：`transform_tracks[k]` = 第 k 帧的摆放。**空 = 静态**（用 local_transform）。
## 与 FRAM 的帧号对齐 —— 播放第 k 帧时，体素取 FRAM 第 k 帧、摆放取这里第 k 项，
## "变换动画"与"体素动画"共用同一个帧号，播放器只需推进一个游标。
## 缺省空 ⇒ 零成本（P2），静态节点不背这条数据。逐帧整数变换与 .vox 的 nTRN.frames 同构。
var transform_tracks: Array[Transform3D] = []


## 第 frame 帧的摆放（无轨道或越界 → 静态 local_transform）。
func transform_at(frame: int) -> Transform3D:
	if frame >= 0 and frame < transform_tracks.size():
		return transform_tracks[frame]
	return local_transform


func is_transform_animated() -> bool:
	return not transform_tracks.is_empty()


## 当前该看到的帧号（同步 FRAM 体素帧）。静态节点恒 0，动画模型返回 active_frame。
func current_frame() -> int:
	return 0

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


# 摆放的 JSON 编解码（NODE 节点 entry 的 `transform` 键）——**全项目唯一实现**。
# 写侧（QVoxelWorld）与读侧（QVoxelWorld / QVoxelAsset）都调这里，杜绝两处各抄一份字段名。

## `transform` 键 → Transform3D。缺失/非法一律回落到恒等。
## 布局：`t` 平移 [x,y,z]（体素单位）、`r` 旋转四元数 [x,y,z,w]、`s` 缩放 [x,y,z]（三者皆可缺省）。
static func transform_from_json(d: Variant) -> Transform3D:
	if not (d is Dictionary):
		return Transform3D.IDENTITY
	var xf: Dictionary = d
	var basis := Basis.IDENTITY
	var r: Variant = xf.get("r")
	if r is Array and (r as Array).size() >= 4:
		var a: Array = r
		var q := Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
		if q.length_squared() > 0.0:
			basis = Basis(q.normalized())
	var s: Variant = xf.get("s")
	if s is Array and (s as Array).size() >= 3:
		var sa: Array = s
		basis = basis * Basis.from_scale(Vector3(float(sa[0]), float(sa[1]), float(sa[2])))
	return Transform3D(basis, _json_vec3(xf.get("t")))


## Transform3D → `transform` 键。**恒等返回空字典**（P2：缺省才是常态），于是调用方
## "非空才写键"即可，不必自己判恒等。
static func transform_to_json(xf: Transform3D) -> Dictionary:
	var d := {}
	if not xf.origin.is_zero_approx():
		d["t"] = [xf.origin.x, xf.origin.y, xf.origin.z]
	var q := xf.basis.get_rotation_quaternion()
	if not q.is_equal_approx(Quaternion.IDENTITY):
		d["r"] = [q.x, q.y, q.z, q.w]
	var sc := xf.basis.get_scale()
	if not sc.is_equal_approx(Vector3.ONE):
		d["s"] = [sc.x, sc.y, sc.z]
	return d


static func _json_vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


# 逐帧摆放轨道的 JSON 编解码（NODE 节点 entry 的 `transform_tracks` 键）。

## `transform_tracks` 键 → 轨道数组。缺省/非法返回空（= 静态）。
static func transform_tracks_from_json(v: Variant) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if v is Array:
		for e in (v as Array):
			out.append(transform_from_json(e))
	return out


## 轨道数组 → `transform_tracks` 键。空轨道返回空数组（调用方据此不写键）。
## 恒等帧写空字典（帧必须占位，不能被"跳过恒等"压缩掉 —— 那会让后续帧号错位）。
static func transform_tracks_to_json(tracks: Array[Transform3D]) -> Array:
	var out: Array = []
	for t in tracks:
		out.append(transform_to_json(t))
	return out
