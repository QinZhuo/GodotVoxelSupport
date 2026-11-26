@tool
class_name QVoxelGroup
extends QVoxelNode
## 组 —— 树上的文件夹（对标 PS / AI 的「图层组」、Blender 的「集合」）。

## 子节点（有序）。
@export var child_nodes: Array[QVoxelNode] = []

func kind() -> String:
	return KIND_GROUP

func children() -> Array[QVoxelNode]:
	return child_nodes

func display_name() -> String:
	if not node_name.is_empty():
		return node_name
	return "未命名组"

## 子树里的节点数（含自己）。
func count_models() -> int:
	var n := 0
	for c in child_nodes:
		if c == null:
			continue
		if c.is_model():
			n += 1
		else:
			n += (c as QVoxelGroup).count_models()
	return n
