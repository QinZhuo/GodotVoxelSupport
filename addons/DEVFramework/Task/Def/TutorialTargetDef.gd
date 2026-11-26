@tool
## 教程目标 — 相对引导宿主 root 的节点路径。
class_name TutorialTargetDef extends Def

## 目标节点路径(相对引导宿主)
@export var node_path: NodePath

## 解析目标节点(宿主为空或节点缺失返回 null)
func resolve(root: Node) -> Node:
	if root == null:
		return null
	return root.get_node_or_null(node_path)
