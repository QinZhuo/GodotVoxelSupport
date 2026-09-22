@tool
## 单条版本更新日志条目
##
## 每个条目只介绍"一个"功能/玩法更新，用一条文本说明；
## [member target] 可指向任意资源（配置 Def / 图片 / 模型等），具体如何展示由项目自定。
class_name ChangelogEntryDef extends Resource

## 更新分类（项目可用于 UI 配色 / 图标）
enum Category {
	NEW,      ## 新增玩法 / 功能
	IMPROVE,  ## 优化调整
	FIX,      ## 修复
	EVENT,    ## 活动
}

## 所属版本号（语义化点分版本，如 "0.5.0"；用于与玩家已见版本比较）
@export var version := ""

## 发布日期（纯展示文本，如 "2026-09-08"）
@export var date := ""

## 分类
@export var category := Category.NEW

## 更新说明（一条文本，介绍这一个功能更新）
@export_multiline var text := ""

## 关联资源（配置 Def / 图片 / 模型等），由项目决定如何展示
@export var target: Resource

## 是否仅 Debug 模式展示（true = 开发 / 测试向内容；判定逻辑由 ChangelogTool 的注入接口提供）
@export var debug_only := false

func _to_string() -> String:
	if text.is_empty():
		return version
	return "%s · %s" % [version, text]
