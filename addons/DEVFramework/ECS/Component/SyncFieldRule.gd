class_name SyncFieldRule
extends Resource

## ECSSyncSystem 字段同步规则条目 —— 场景/Inspector 可配置的单个同步规则:

@export var comp: Script        # ECS 组件脚本(必须继承 ECSComponent)
@export var field: StringName   # 要同步的 ECS 组件字段名
@export var prop: StringName    # 关联节点的属性名(如 position / visual_size / modulate)
