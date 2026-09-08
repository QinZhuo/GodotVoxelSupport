@tool
## 更新日志定义：一个版本的若干更新条目
##
## 纯配置（Def），在 Assets/Def/ 下做成 .tres，由 ChangelogTool 扫描读取。
## 参考示例：res://Assets/Def/Changelog/ChangelogExample.tres
class_name ChangelogDef extends Def

## 更新条目（每个条目介绍一个功能更新）
@export var entries: Array[ChangelogEntryDef] = []

## 本定义覆盖的最高版本号（无条目时返回空串）
func get_max_version() -> String:
	var max_v := ""
	for entry in entries:
		if entry and not entry.version.is_empty() \
				and (max_v.is_empty() or SaveTool.is_version_newer(entry.version, max_v)):
			max_v = entry.version
	return max_v
