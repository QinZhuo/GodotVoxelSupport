@tool
class_name DevStructureTools
extends EditorScript

const DevProjectSetup := preload("res://addons/DEVFramework/Tool/DevProjectSetup.gd")

## 点击菜单时执行: 一键创建框架约定的项目目录结构
func _run() -> void:
	DevProjectSetup.create_structure()