@tool
## 一行对话 — 只说"说什么"，不说"怎么显示"。
class_name DialogueLineDef extends Resource

## 说话人标识（项目自定义；空 = 旁白）
@export var speaker: StringName = &""
## 翻译 key（非空优先；空则用 text）
@export var text_key: StringName = &""
## 直接文案（支持 bbcode）
@export_multiline var text := ""
## >0 = 到点自动推进秒数；0 = 等玩家推进
@export var hold := 0.0
## 任意扩展数据（portrait/表情/音效/事件名…由 view 自己解释）
@export var meta := {}


func display_text() -> String:
	return tr(String(text_key)) if text_key != &"" else text
