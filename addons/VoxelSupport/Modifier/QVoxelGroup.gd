@tool
class_name QVoxelGroup
extends QVoxelNode
## 组 —— 树上的文件夹（对标 PS / AI 的「图层组」、Blender 的「集合」）。
##
## 【它自己什么内容都没有】组不存体素：它的内容是**子树合并的结果**（见 QVoxelEvalEngine 的
## 树形求值）。于是组的内存成本为零，也不需要"组的画布尺寸"这种东西 —— 组的中间体积取
## "子树内容的并集包围盒"（紧致盒），512³ 的一次全量分配（537 MB）因此不会因为"建了个组"而发生。
##
## 【为什么组是唯一可持有子节点者】模型是叶子（它持有手绘体素，见 QVoxelModel）。这条界线让
## "谁能被拖进谁"变成一个类型问题，而不是一条要记住的规则。
##
## 【组也能挂滤镜】QVoxelNode.modifiers 作用于本组的**合并结果** —— "给整组岩石统一去色 / 侵蚀 /
## 镜像"因此是一件事。这就是"在层级上挂滤镜"。

## 子节点（有序）。**唯一真值** —— 树视图是它的纯投影，落位只改它，然后整棵重建。
@export var child_nodes: Array[QVoxelNode] = []


func kind() -> String:
	return KIND_GROUP


func children() -> Array[QVoxelNode]:
	return child_nodes


func display_name() -> String:
	if not node_name.is_empty():
		return node_name
	return "未命名组"


## 子树里的节点数（含自己）。UI 折叠时显示"这组里有 N 个模型"。
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
