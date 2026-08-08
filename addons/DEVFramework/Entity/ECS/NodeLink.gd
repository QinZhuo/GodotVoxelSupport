class_name NodeLink
extends ECSComponent

## NodeLink —— ECS 实体与 Godot 节点的"纯数据关联"组件。
##
## 这是"中期方案"的核心: 不再由每个实体自己同步位置,
## 而是用本组件记录"实体 ↔ 节点"的关联, 由 ECSSyncSystem 批量同步。
##
## 纯数据原则:
##   - 只存节点路径(String)和同步配置, 不持有 Node 引用 → 可序列化存档
##   - 运行时由 ECSSyncSystem 通过路径查找节点
##
## 配合使用:
##   - 实体 + NodeLink + 位置组件(如 TransformComponent/ECSDemoMoveComponent)
##   - ECSSyncSystem 自动把 ECS 位置 → node.position
##   - 节点交互(Godot 逻辑)用 ECSNode 便利层或直接 world.get/set_field

## 关联的 Godot 节点路径(相对场景根, 可序列化)
@export var node_path: String = ""

## 是否参与 ECSSyncSystem 的位置同步
@export var sync_position: bool = true

## 位置组件类名(参与同步时使用)
@export var pos_component: String = ""

## 位置字段名
@export var pos_field: String = "pos"

## 位置字段是 x/y 两个 float(而非 Vector2/3 单字段)
@export var pos_use_xy: bool = false
