@tool
class_name DevAudioTools
extends EditorScript

const DevAudioExamples := preload("res://addons/DEVFramework/Tool/DevAudioExamples.gd")

## 点击菜单时执行: 一键生成示例音频定义
func _run() -> void:
	var results := DevAudioExamples.create_all()
	LogTool.log("音频", "示例生成完成: ", results)