@tool
class_name FurnitureTableDef extends Resource
## 家具槽位加权表 — 城镇室内生成用（S6）
##
## slot_name 对应户型模板中的槽位字符（如 "B"=床、"T"=桌、"H"=炉灶），
## items 为该槽位可抽的具体家具变体（weight 加权）。

## 槽位字符（与 TemplateDef.lines 中的字符对应，大写字母约定）
@export var slot_name := "B"
## 该槽位的家具变体加权表
@export var items: Array[ContentEntryDef] = []

func _to_string() -> String:
	return "Furniture[%s x%d]" % [slot_name, items.size()]
