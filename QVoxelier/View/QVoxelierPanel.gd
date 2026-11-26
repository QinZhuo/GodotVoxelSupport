@tool
class_name QVoxelierPanel
extends UIPanel
## QVoxelier 面板基类：把「长相 / 层级 / 输入姿态」三件每个面板都要做一遍的事收在一处。

func _ready() -> void:
	theme = QVoxelUi.theme()
	layer = UITool.Layer.HUD
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	open()

## 子类重写：构建界面内容。
func _build() -> void:
	pass
