class_name ECSParent
extends ECSComponent

## 父子关系组件 —— target = 父实体 ID(-1 = 无父)。
## 配合 ECSWorld.set_parent / get_parent / get_children / clear_parent 使用:
## 关系索引(_parent_children)由这些 API 自动维护, 实体销毁时框架自动清理(解除关联)。
## 也可手动加本组件再 set_field target(此时索引由 set_parent 同步, 直接改字段需自查索引)。

@export var target: int = -1   # 父实体 ID(-1 = 无父)
