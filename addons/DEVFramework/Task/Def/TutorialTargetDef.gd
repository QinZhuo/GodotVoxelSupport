@tool
## 教程目标 — 相对引导宿主 root 的节点路径。2D 控件 / Node2D 精灵 / 3D 模型通用,
## 屏幕区域换算由 Spotlight 统一负责。
class_name TutorialTargetDef extends Def

## 目标节点路径(相对引导宿主)
@export var node_path: NodePath

## 高亮区外扩像素(小目标加一点更好看也更好点)
@export var padding := 0.0


## 解析目标节点(宿主为空或节点缺失返回 null)
func resolve(root: Node) -> Node:
	if root == null:
		return null
	return root.get_node_or_null(node_path)
