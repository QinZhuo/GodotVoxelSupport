class_name NodeLink
extends ECSComponent

## NodeLink —— ECS 实体与 Godot 节点的"纯数据关联"组件。
##
## 只保存 node_path(实体 ↔ 节点 关联)。**同步哪些字段由 ECSSyncSystem.add_field_rule
## 注册的规则决定**(位置/任意字段 → 节点属性), 本组件不再保存任何同步配置。

## 关联的 Godot 节点绝对路径(如 /root/Scene/WorldRoot/Ball0, 可序列化)
@export var node_path: String = ""
