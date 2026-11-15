class_name NodeLink
extends ECSComponent

## NodeLink —— ECS 实体与 Godot 节点的"纯数据关联"组件。

## 关联的 Godot 节点绝对路径(如 /root/Scene/WorldRoot/Ball0, 可序列化)
@export var node_path: String = ""
