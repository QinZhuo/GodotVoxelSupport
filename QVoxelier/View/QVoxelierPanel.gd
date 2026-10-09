@tool
class_name QVoxelierPanel
extends UIPanel
## QVoxelier 面板基类：把「长相 / 层级 / 输入姿态」三件每个面板都要做一遍的事收在一处。
##
## 【三件事】
##   ① theme = QVoxelUi.theme() —— 全应用共享同一个主题实例，面板长相由此统一
##      （见 QVoxelUi 的类文档：新面板只描述结构，不描述长相）；
##   ② layer = HUD —— 应用栏 / 工具坞 / 调色板 / 状态栏都是**常驻抬头层**：
##      多元素共存、不参与 back() 返回链（按 Esc 该取消的是笔，不是关掉工具栏）；
##   ③ mouse_filter = IGNORE + 子控件 FOCUS_NONE —— 面板压在视口上，但空白处不吞事件
##      （否则视口里会多出几块"点不进去"的死区）；键盘也一律留给视口当热键。
##
## 【子类只实现 _build()】`_ready` 的次序（主题 → 层级 → 构建 → open）固定且
## 少一步就表现为"面板不显示"或"样式没生效"，故不给子类留出重写的缝隙。
##
## 【触摸与鼠标同一套】所有面板只依赖 Button 的 pressed 态表达选中 —— 触摸没有 hover，
## 于是"选中必须常驻可见"就成了本基类下所有控件的共同约定（详见 QVoxelUi 类文档）。


func _ready() -> void:
	theme = QVoxelUi.theme()
	layer = UITool.Layer.HUD
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	open()


## 子类重写：构建界面内容。此方法在主题与层级就绪之后调用。
func _build() -> void:
	pass
