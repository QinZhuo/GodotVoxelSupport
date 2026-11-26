@tool
@abstract
class_name QVoxelNode
extends Resource
## 节点 —— 场景树上的一格（组或模型），树形层级结构的唯一元素类型。

## 落盘判别键（NODE 的 nodes[] 里每项的 kind）。
const KIND_GROUP := "group"
const KIND_MODEL := "model"

## 全部 kind（读盘校验 / 报错文案用）。
const KINDS: PackedStringArray = [KIND_GROUP, KIND_MODEL]

## 显示名（写进 NODE 节点的 name 键）。
@export var node_name := ""

## 可见性。
@export var visible := true

## 锁定。
@export var locked := false

## 本节点在父画布里的**摆放**（位置 + 旋转）。
@export var local_transform: Transform3D = Transform3D.IDENTITY

## 位置视图：`local_transform.origin` 的整数形态。
var offset: Vector3i:
	get:
		return Vector3i(
				roundi(local_transform.origin.x),
				roundi(local_transform.origin.y),
				roundi(local_transform.origin.z))
	set(value):
		local_transform.origin = Vector3(value)

## 组的运行时编号（模型不用它，走落盘的 `model_id`）。
var node_uid := 0

## 树面板里的展开状态。
var expanded_in_tree := true

## 结构性改动（改名、可见性、位置、树形增删）。
signal content_changed

# 子类回答的问题

## 落盘判别键，取 KIND_GROUP / KIND_MODEL 之一。
@abstract
func kind() -> String

## 子节点（只有组非空）。
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
