@tool
class_name QVoxelierDock
extends QVoxelierPanel
## 右侧抽屉 —— 竖排若干可折叠分组（颜色 / 对象 / 图层 / 变换）。
##
## 【为什么右列要有个容器，而不是四个各自定位的面板】四个面板各自"记住自己在屏幕哪一行"
## 是四份会互相打架的布局状态：折叠上面那组，下面三组必须整体上移 —— 容器一次就把这件事做完。
## 换句话说，位置关系交给容器，面板只管内容。
##
## 【为什么贴右上】左上与底部都已占（工具坞 / 视图栏 / 调色板 / 朝向指示器）。
## 右上还顺带贴着"应用栏"的下沿，于是纵向只有一条连续的面板带，视线不必来回横跳。
##
## 【宽度随密度档】触摸档要更宽（滑块更好点、文字更大），桌面档收窄把视口让出来。

var _col: VBoxContainer


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_right = -QVoxelUi.space_m()
	offset_top = QVoxelUi.bar_height() + QVoxelUi.space_m()
	var w := float(QVoxelUi.dock_width()) + QVoxelUi.space_l()
	offset_left = offset_right - w

	_col = QVoxelUi.vbox(QVoxelUi.space_s())
	_col.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(_col)
	# 高度由内容决定：容器长多高，本控件（它的矩形会被调试器/自动化工具读到）就跟着多高。
	_col.resized.connect(func(): offset_bottom = offset_top + _col.size.y)


## 追加一组。**只在 App 装配时调用**（组是从上到下固定的阅读顺序，不支持插队）。
func add_section(s: QVoxelierSection) -> void:
	_col.add_child(s)
