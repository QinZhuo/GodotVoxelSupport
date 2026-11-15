class_name ECSComponent
extends Resource

## ECS 组件基类 —— 纯数据 schema 声明。

## 收集本组件 schema 信息(统一走 ECSNative.collect_schema)。
func get_schema() -> Dictionary:
	return ECSNative.collect_schema(self)
